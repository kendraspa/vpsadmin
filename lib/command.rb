require 'lib/executor'
require 'lib/handlers/vpsadmin'
require 'lib/handlers/node'
require 'lib/handlers/vps'
require 'lib/handlers/zfsvps'
require 'lib/handlers/clone'
require 'lib/handlers/migration'
require 'lib/handlers/firewall'
require 'lib/handlers/mailer'
require 'lib/handlers/dataset'
require 'lib/handlers/backuper'
require 'lib/handlers/dummy'

require 'rubygems'
require 'json'

class Command
  attr_reader :trans

  @@handlers = {}

  def initialize(trans)
    @trans = trans
    @output = {}
    @status = :failed
    @m_attr = Mutex.new
  end

  def execute
    cmd = handler

    unless cmd
      @output[:error] = "Unsupported command"
      return false
    end

    begin
      param = JSON.parse(@trans["t_param"])
    rescue
      @output[:error] = "Bad param syntax"
      return false
    end

    @executor = Kernel.const_get(cmd[:class]).new(@trans["t_vps"], param, self)

    @m_attr.synchronize { @time_start = Time.new.to_i }

    begin
      ret = @executor.method(cmd[:method]).call

      begin
        @status = ret[:ret]

        if @status == nil
          bad_value(cmd)
        end
      rescue
        bad_value(cmd)
      end
    rescue CommandFailed => err
      @status = :failed
      @output[:cmd] = err.cmd
      @output[:exitstatus] = err.rc
      @output[:error] = err.output
    rescue CommandNotImplemented
      @status = :failed
      @output[:error] = "Command not implemented"
    rescue => err
      @status = :failed
      @output[:error] = err.inspect
      @output[:backtrace] = err.backtrace
    end

    fallback if @status == :failed

    @time_end = Time.new.to_i
  end

  def bad_value(cmd)
    raise CommandFailed.new("process handler return value", 1, "#{cmd[:class]}.#{cmd[:method]} did not return expected value")
  end

  def save(db)
    db.prepared(
        "UPDATE transactions SET t_done=1, t_success=?, t_output=?, t_real_start=?, t_end=? WHERE t_id=?",
        {:failed => 0, :ok => 1, :warning => 2}[@status], (@executor ? @output.merge(@executor.output) : @output).to_json, @time_start, @time_end, @trans["t_id"]
    )

    @executor.post_save(db) if @executor
  end

  def dependency_failed(db)
    @output[:error] = "Dependency failed"
    @status = :failed
    save(db)
  end

  def killed(hard)
    @executor.killed

    if hard
      @output[:error] = 'Killed'
      @status = :failed

      fallback
    end
  end

  def fallback
    @output[:fallback] = {}

    begin
      fallback = JSON.parse(@trans['t_fallback'])

      unless fallback.empty?
        log "Transaction #{@trans['t_id']} failed, falling back"

        transaction = Transaction.new
        @output[:fallback][:transactions] = []

        fallback['transactions'].each do |t|
          @output[:fallback][:transactions] << transaction.queue({
                                                                     :m_id => t['t_m_id'],
                                                                     :node => t['t_server'],
                                                                     :vps => t['t_vps'],
                                                                     :type => t['t_type'],
                                                                     :depends => t['t_depends_on'],
                                                                     :urgent => t['t_urgent'],
                                                                     :priority => t['t_priority'],
                                                                     :param => t['t_params'],
                                                                 })
        end
      end
    rescue => err
      @output[:fallback][:msg] = 'Fallback failed'
      @output[:fallback][:error] = err.inspect
      @output[:fallback][:backtrace] = err.backtrace
    end
  end

  def id
    @trans["t_id"]
  end

  def worker_id
    if @trans.has_key?("t_vps")
      @trans["t_vps"].to_i
    else
      0
    end
  end

  def type
    @trans["t_type"]
  end

  def urgent?
    @trans['t_urgent'].to_i == 1
  end

  def handler
    @@handlers[@trans["t_type"].to_i]
  end

  def step
    @executor.step
  end

  def subtask
    @executor.subtask
  end

  def time_start
    @m_attr.synchronize { @time_start }
  end

  def Command.load_handlers
    $CFG.get(:vpsadmin, :handlers).each do |klass, cmds|
      cmds.each do |cmd, method|
        @@handlers[cmd] = {:class => klass, :method => method}
        log "Cmd ##{cmd} => #{klass}.#{method}"
      end
    end
  end
end
