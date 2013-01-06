require 'lib/console'

require 'rubygems'
require 'eventmachine'
require 'json'

class RemoteControl < EventMachine::Connection
	@@handlers = {}
	
	def initialize(daemon)
		@daemon = daemon
	end
	
	def post_init
		send_data({:version => VpsAdmind::VERSION}.to_json)
	end
	
	def receive_data(data)
		begin
			req = JSON.parse(data)
		rescue TypeError
			return error("Syntax error")
		end
		
		cmd = @@handlers[req["command"].to_sym]
		
		return error("Unsupported command") unless cmd
		
		executor = Kernel.const_get(cmd[:class]).new(0, {}, @daemon)
		output = {}
		
		begin
			ret = executor.method(cmd[:method]).call
		rescue CommandFailed => err
			output[:cmd] = err.cmd
			output[:exitstatus] = err.rc
			output[:error] = err.output
			error(output)
		end
		
		if ret[:ret] == :ok
			ok(ret[:output])
		else
			error(ret[:output])
		end
	end
	
	def unbind
		
	end
	
	def error(err)
		send_data({:status => :failed, :error => err}.to_json)
	end
	
	def ok(res)
		send_data({:status => :ok, :response => res}.to_json)
	end
	
	def RemoteControl.load_handlers
		$APP_CONFIG[:remote][:handlers].each do |klass, cmds|
			cmds.each do |cmd|
				@@handlers[cmd] = {:class => klass, :method => cmd}
				puts "Remote cmd #{cmd} => #{klass}.#{cmd}"
			end
		end
	end
end
