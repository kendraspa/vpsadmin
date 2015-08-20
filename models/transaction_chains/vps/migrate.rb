module TransactionChains
  # Migrate VPS to another node.
  class Vps::Migrate < ::TransactionChain
    label 'Migrate'
    urgent_rollback

    has_hook :pre_start
    has_hook :post_start

    def link_chain(vps, dst_node, replace_ips, resources = nil,
                   handle_ips = true, reallocate_ips = true)
      lock(vps)
      concerns(:affect, [vps.class.name, vps.id])

      dst_vps = ::Vps.find(vps.id)
      dst_vps.node = dst_node

      # Save VPS state
      running = vps.running?

      # Create target dataset in pool.
      # No new dataset in pool is created in database, it is simply
      # moved to another pool.
      src_dip = vps.dataset_in_pool
      @src_pool = src_dip.pool
      @dst_pool = dst_node.pools.hypervisor.take!

      lock(src_dip)

      # Transfer resources if the destination node is in a different
      # environment.
      if vps.node.environment_id != dst_node.environment_id
        resources_changes = vps.transfer_resources_to_env!(
            vps.user,
            dst_node.environment,
            resources
        )
      end

      # Copy configs, create /vz/root/$veid
      append(Transactions::Vps::CopyConfigs, args: [vps, dst_node])
      append(Transactions::Vps::CreateRoot, args: [vps, dst_node])

      datasets = []

      vps.dataset_in_pool.dataset.subtree.arrange.each do |k, v|
        datasets.concat(recursive_serialize(k, v))
      end

      # Create datasets
      datasets.each do |pair|
        src, dst = pair

        # Transfer resources
        resources_changes ||= {}

        if vps.node.environment_id != dst_node.environment_id
          # This code expects that the datasets have a just one cluster resource,
          # which is diskspace.
          changes = src.transfer_resources_to_env!(vps.user, dst_node.environment)
          changes[changes.keys.first][:row_id] = dst.id
          resources_changes.update(changes)

        else
          ::ClusterResourceUse.for_obj(src).each do |use|
            resources_changes[use] = {row_id: dst.id}
          end
        end

        append(Transactions::Storage::CreateDataset, args: dst) do
          create(dst)
        end

        props = {}

        src.dataset_properties.where(inherited: false).each do |p|
          props[p.name.to_sym] = [p, p.value]
        end

        append(Transactions::Storage::SetDataset, args: [dst, props]) unless props.empty?
      end

      # Unmount VPS datasets & snapshots in other VPSes
      mounts = MountMigrator.new(self, vps, dst_vps)
      mounts.umount_others

      # Transfer datasets
      migration_snapshots = []

      datasets.each do |pair|
        src, dst = pair

        # Transfer private area. All subdatasets are transfered as well.
        # The two step transfer is done even if the VPS seems to be stopped.
        # It does not have to be the case.
        # First transfer is done when the VPS is running.
        migration_snapshots << use_chain(Dataset::Snapshot, args: src)
        use_chain(Dataset::Transfer, args: [src, dst])
      end

      # Stop the VPS
      use_chain(Vps::Stop, args: vps)

      datasets.each do |pair|
        src, dst = pair

        # Seconds transfer is done when the VPS is stopped
        migration_snapshots << use_chain(Dataset::Snapshot, args: src, urgent: true)
        use_chain(Dataset::Transfer, args: [src, dst], urgent: true)
      end

      dst_ip_addresses = vps.ip_addresses

      # Migration to different location - remove or replace
      # IP addresses
      if vps.node.location != dst_vps.node.location && handle_ips
        # Add the same number of IP addresses from the target location
        if replace_ips
          dst_ip_addresses = []

          vps.ip_addresses.each do |ip|
            replacement = ::IpAddress.pick_addr!(dst_vps.user, dst_vps.node.location, ip.ip_v)

            append(Transactions::Vps::IpDel, args: [dst_vps, ip, false], urgent: true) do
              edit(ip, vps_id: nil)
            end

            append(Transactions::Vps::IpAdd, args: [dst_vps, replacement], urgent: true) do
              edit(replacement, vps_id: dst_vps.veid)

              if !replacement.user_id && dst_vps.node.environment.user_ip_ownership
                edit(replacement, user_id: dst_vps.user_id)
              end
            end

            dst_ip_addresses << replacement
          end

        else
          # Remove all IP addresses
          dst_ip_addresses = []
          ips = []

          vps.ip_addresses.each { |ip| ips << ip }
          use_chain(Vps::DelIp, args: [dst_vps, ips, vps, false, reallocate_ips],
                    urgent: true)
        end
      end

      # Regenerate mount scripts of the migrated VPS
      mounts.datasets = datasets
      mounts.remount_mine

      # Restore VPS state
      call_hooks_for(:pre_start, self, args: [dst_vps, running])
      use_chain(Vps::Start, args: dst_vps, urgent: true) if running
      call_hooks_for(:post_start, self, args: [dst_vps, running])

      # Remount and regenerate mount scripts of mounts in other VPSes
      mounts.remount_others

      # Remove migration snapshots
      migration_snapshots.each do |sip|
        dst_sip = sip.snapshot.snapshot_in_pools.joins(:dataset_in_pool).where(
            dataset_in_pools: {pool_id: @dst_pool.id}
        ).take!

        use_chain(SnapshotInPool::Destroy, args: dst_sip, urgent: true)
      end

      # Move the dataset in pool to the new pool in the database
      append(Transactions::Utils::NoOp, args: dst_node.id, urgent: true) do
        edit(vps, dataset_in_pool_id: datasets.first[1].id)
        edit(vps, vps_server: dst_node.id)

        # Transfer resources
        resources_changes.each do |use, changes|
          edit(use, changes) unless changes.empty?
        end

        # Handle dataset properties, actions and group snapshots
        datasets.each do |pair|
          src, dst = pair

          src.dataset_properties.all.each do |p|
            edit(p, dataset_in_pool_id: dst.id)
          end

          src.group_snapshots.all.each do |gs|
            edit(gs, dataset_in_pool_id: dst.id)
          end

          src.src_dataset_actions.all.each do |da|
            edit(da, src_dataset_in_pool_id: dst.id)
          end

          src.dst_dataset_actions.all.each do |da|
            edit(da, dst_dataset_in_pool_id: dst.id)
          end
        end
      end

      # Call DatasetInPool.migrated hook
      datasets.each do |src, dst|
        src.call_hooks_for(:migrated, self, args: [src, dst])
      end

      # Setup firewall and shapers 
      # Unregister from firewall and remove shaper on source node
      if handle_ips
        use_chain(Vps::FirewallUnregister, args: vps, urgent: true)
        use_chain(Vps::ShaperUnset, args: vps, urgent: true)
      end

      # Is is needed to register IP in fw and shaper when changing location,
      # as IPs are removed or replaced sooner.
      if vps.node.location == dst_vps.node.location
        # Register to firewall and set shaper on destination node
        use_chain(Vps::FirewallRegister, args: [dst_vps, dst_ip_addresses], urgent: true)
        use_chain(Vps::ShaperSet, args: [dst_vps, dst_ip_addresses], urgent: true)
      end

      # Destroy old dataset in pools
      # Do not delete repeatable tasks - they are re-used for new datasets
      use_chain(DatasetInPool::Destroy, args: [src_dip, true, true, false])

      # Destroy old root
      append(Transactions::Vps::Destroy, args: vps)

      # fail 'ohnoes'
    end

    def recursive_serialize(dataset, children)
      ret = []

      # First parents
      dip = dataset.dataset_in_pools.where(pool: @src_pool).take

      return ret unless dip

      lock(dip)

      dst = ::DatasetInPool.create!(
          pool: @dst_pool,
          dataset_id: dip.dataset_id,
          label: dip.label
      )

      lock(dst)

      ret << [dip, dst]

      # Then children
      children.each do |k, v|
        if v.is_a?(::Dataset)
          dip = v.dataset_in_pools.where(pool: @src_pool).take
          next unless dip

          lock(dip)

          dst = ::DatasetInPool.create!(
              pool: @dst_pool,
              dataset_id: dip.dataset_id,
              label: dip.label
          )

          lock(dst)

          ret << [dip, dst]

        else
          ret.concat(recursive_serialize(k, v))
        end
      end

      ret
    end

    # Handle my mounts of datasets and snapshots of other VPSes
    #   local -> local - no change needed
    #   local -> remote - change mount, create clone for snapshot if needed
    #   remote -> remote - regenerate mounts to handle different IPs, move
    #                      snapshot clone to new destination
    #   remote -> local - change mount, remove clone of snapshot if needed
    # Handle mounts of my datasets and snapshots in other VPSes
    #   is the same
    class MountMigrator
      def initialize(chain, src_vps, dst_vps)
        @chain = chain
        @src_vps = src_vps
        @dst_vps = dst_vps
        @my_mounts = []
        @others_mounts = {}

        sort_mounts
      end

      def datasets=(datasets)
        # Map of source datasets to destination datasets
        @ds_map = {}

        datasets.each do |pair|
          # @ds_map[ src ] = dst
          @ds_map[pair[0]] = pair[1]
        end
      end

      def umount_others
        @others_mounts.each do |v, vps_mounts|
          @chain.append(Transactions::Vps::Umount, args: [v, vps_mounts])
        end
      end

      def remount_mine
        obj_changes = {}

        @my_mounts.each do |m|
          obj_changes.update(
              migrate_mine_mount(m)
          )
        end
        
        @chain.use_chain(Vps::Mounts, args: @dst_vps, urgent: true)

        unless obj_changes.empty?
          @chain.append(Transactions::Utils::NoOp, args: @dst_vps.vps_server,
                        urgent: true) do
            obj_changes.each do |obj, changes|
              edit_before(obj, changes)
            end
          end
        end
      end

      def remount_others
        @others_mounts.each do |vps, mounts|
          obj_changes = {}

          mounts.each do |m|
            obj_changes.update(
                migrate_others_mount(m)
            )
          end

          @chain.use_chain(Vps::Mounts, args: vps, urgent: true)

          @chain.append(
              Transactions::Vps::Mount,
              args: [vps, mounts.reverse], urgent: true
          ) do
            obj_changes.each do |obj, changes|
              edit_before(obj, changes)
            end
          end
        end
      end

      private
      def sort_mounts
        # Fetch ids of all descendant datasets in pool
        dataset_in_pools = @src_vps.dataset_in_pool.dataset.subtree.joins(
            :dataset_in_pools
        ).where(
            dataset_in_pools: {pool_id: @src_vps.dataset_in_pool.pool_id}
        ).pluck('dataset_in_pools.id')

        # Fetch all snapshot in pools of above datasets
        snapshot_in_pools = []

        ::SnapshotInPool.where(dataset_in_pool_id: dataset_in_pools).each do |sip|
          snapshot_in_pools << sip.id

          if sip.reference_count > 1
            # This shouldn't be possible, as every snapshot can be mounted
            # just once.
            fail "snapshot (s=#{sip.snapshot_id},sip=#{sip.id}) has too high a reference count"
          end
        end

        ::Mount.includes(
            :vps, :snapshot_in_pool, dataset_in_pool: [:dataset, pool: [:node]]
        ).where(
            'vps_id = ? OR (dataset_in_pool_id IN (?) OR snapshot_in_pool_id IN (?))',
            @src_vps.id, dataset_in_pools, snapshot_in_pools
        ).order('dst DESC').each do |mnt|
          if mnt.vps_id == @src_vps.id
            @my_mounts << mnt

          else
            @others_mounts[mnt.vps] ||= []
            @others_mounts[mnt.vps] << mnt
          end
        end
      end

      # Migrate a mount that is mounted in the migrated VPS (therefore mine)
      # and the mounted dataset or snapshot can be of the migrated VPS or from
      # elsewhere.
      def migrate_mine_mount(mnt)
        dst_dip = @ds_map[mnt.dataset_in_pool]

        is_subdataset = \
          mnt.dataset_in_pool.pool.node_id == @src_vps.vps_server && \
          mnt.vps.dataset_in_pool.dataset.subtree_ids.include?(
              mnt.dataset_in_pool.dataset.id
          )
        
        is_local = @src_vps.vps_server == mnt.dataset_in_pool.pool.node_id
        is_remote = !is_local

        if is_subdataset
          become_local = @dst_vps.vps_server == dst_dip.pool.node_id
        else
          become_local = @dst_vps.vps_server == mnt.dataset_in_pool.pool.node_id
        end

        become_remote = !become_local

        is_snapshot = !mnt.snapshot_in_pool.nil?
        new_snapshot = if is_snapshot && is_subdataset
                         ::SnapshotInPool.where(
                             snapshot_id: mnt.snapshot_in_pool.snapshot_id,
                             dataset_in_pool: dst_dip
                         ).take!
                       else
                         nil
                       end

        original = {
            dataset_in_pool_id: mnt.dataset_in_pool_id,
            snapshot_in_pool_id: mnt.snapshot_in_pool_id,
            mount_type: mnt.mount_type,
            mount_opts: mnt.mount_opts
        }

        changes = {}

        # Local -> remote:
        #   - change mount type
        #   - clone snapshot if needed
        if is_local && become_remote
          mnt.mount_type = 'nfs'
          mnt.mount_opts = '-n -t nfs -overs=3'

          if is_snapshot
            @chain.append(
                Transactions::Storage::CloneSnapshot,
                args: mnt.snapshot_in_pool, urgent: true
            ) do
              increment(mnt.snapshot_in_pool, :reference_count)
            end
          end

        # Remote -> local:
        #   - change mount type
        #   - remote snapshot clone if needed
        elsif is_remote && become_local
          mnt.mount_type = 'bind'
          mnt.mount_opts = '--bind'

          if is_snapshot
            @chain.append(
                Transactions::Storage::RemoveClone,
                args: mnt.snapshot_in_pool, urgent: true
            ) do
              decrement(mnt.snapshot_in_pool, :reference_count)
            end
          end

        # Remote -> remote:
        elsif is_remote && become_remote

        # Local -> local:
        #   - nothing to do
        elsif is_local && become_local

        end

        if is_subdataset
          mnt.dataset_in_pool = dst_dip

          if is_snapshot
            # Remove the mount link from snapshot_in_pool, because it would
            # delete mount, when the snapshot gets deleted in
            # DatasetInPool::Destroy.
            changes[mnt.snapshot_in_pool] = {
                mount_id: mnt.snapshot_in_pool.mount_id
            }
            mnt.snapshot_in_pool.update!(mount: nil)

            changes[new_snapshot] = {mount_id: nil}
            new_snapshot.update!(mount: mnt)
            
            mnt.snapshot_in_pool = new_snapshot 
          end
        end

        mnt.save!

        changes[mnt] = original
        changes
      end

      # Migrate a mount that is mounted in another VPS (not the one being
      # migrated). The mounted dataset or snapshot belongs to the migrated VPS.
      def migrate_others_mount(mnt)
        dst_dip = @ds_map[mnt.dataset_in_pool]

        is_local = @src_vps.vps_server == mnt.vps.vps_server
        is_remote = !is_local

        become_local = @dst_vps.vps_server == mnt.vps.vps_server
        become_remote = !become_local

        is_snapshot = !mnt.snapshot_in_pool.nil?
        new_snapshot = if is_snapshot
                         ::SnapshotInPool.where(
                             snapshot_id: mnt.snapshot_in_pool.snapshot_id,
                             dataset_in_pool: dst_dip
                         ).take!
                       else
                         nil
                       end

        original = {
            dataset_in_pool_id: mnt.dataset_in_pool_id,
            snapshot_in_pool_id: mnt.snapshot_in_pool_id,
            mount_type: mnt.mount_type,
            mount_opts: mnt.mount_opts
        }

        changes = {}

        # Local -> remote:
        #   - change mount type
        #   - clone snapshot if needed
        if is_local && become_remote
          mnt.mount_type = 'nfs'
          mnt.mount_opts = '-n -t nfs -overs=3'

          if is_snapshot
            @chain.append(
                Transactions::Storage::CloneSnapshot,
                args: new_snapshot, urgent: true
            ) do
              increment(new_snapshot, :reference_count)
            end
          end

        # Remote -> local:
        #   - change mount type
        #   - remote snapshot clone if needed
        elsif is_remote && become_local
          mnt.mount_type = 'bind'
          mnt.mount_opts = '--bind'

          if is_snapshot
            @chain.append(
                Transactions::Storage::RemoveClone,
                args: mnt.snapshot_in_pool, urgent: true
            ) do
              decrement(mnt.snapshot_in_pool, :reference_count)
            end
          end

        # Remote -> remote:
        #   - update node IP address, remove snapshot on src and create on dst
        #     node
        elsif is_remote && become_remote
          if is_snapshot
            @chain.append(
                Transactions::Storage::RemoveClone,
                args: mnt.snapshot_in_pool, urgent: true
            )
            @chain.append(
                Transactions::Storage::CloneSnapshot,
                args: new_snapshot, urgent: true
            )
          end

        # Local -> local:
        #   - nothing to do
        elsif is_local && become_local

        end

        mnt.dataset_in_pool = dst_dip

        if is_snapshot
          # Remove the mount link from snapshot_in_pool, because it would
          # delete mount, when the snapshot gets deleted in
          # DatasetInPool::Destroy.
          changes[mnt.snapshot_in_pool] = {
              mount_id: mnt.snapshot_in_pool.mount_id
          }
          mnt.snapshot_in_pool.update!(mount: nil)

          changes[new_snapshot] = {mount_id: nil}
          new_snapshot.update!(mount: mnt)
          
          mnt.snapshot_in_pool = new_snapshot 
        end

        mnt.save!

        changes[mnt] = original
        changes
      end
    end
  end
end
