module VpsAdmind
  class Commands::Vps::Umount < Commands::Base
    handle 5303
    needs :system, :vz, :vps, :zfs

    def exec
      return ok unless status[:running]

      @mounts.each do |mnt|
        runscript('preumount', mnt['preumount']) if mnt['runscripts']
        syscmd("#{$CFG.get(:bin, :umount)} #{mnt['umount_opts']} #{ve_root}/#{mnt['dst']}", [1])
        runscript('postumount', mnt['postumount']) if mnt['runscripts']
      end

      ok
    end

    def rollback
      call_cmd(Commands::Vps::Mount, {
          :vps_id => @vps_id,
          :mounts => @mounts.reverse,
          :runscripts => false
      })
    end
  end
end
