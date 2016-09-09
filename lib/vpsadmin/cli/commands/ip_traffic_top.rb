require 'curses'

module VpsAdmin::CLI::Commands
  class IpTrafficTop < BackupDataset
    include Curses

    REFRESH_RATE = 10

    cmd :ip_traffic, :top
    args ''
    desc 'Live IP traffic monitor'
    
    def options(opts)
      @opts = {
          params: %i(bytes_in bytes_out bytes),
          unit: :bits,
      }

      opts.on('-o', '--parameters PARAMS', 'Output parameters to show, separated by comma') do |v|
        @opts[:params] = v.split(',').map(&:to_sym)
      end

      opts.on('--unit UNIT', %w(bytes bits), 'Select data unit (bytes or bits)') do |v|
        @opts[:unit] = v.to_sym
      end

      opts.on('-s', '--sort PARAM', 'Order by specified output parameter') do |v|
        @sort_desc = v.start_with?('-')
        @sort_param = (v.start_with?('-') ? v[1..-1] : v).to_sym
      end
    end

    def exec(args)
      @sort_desc = true if @sort_desc.nil?
      @sort_param ||= :bytes

      init_screen
      start_color
      crmode
      stdscr.keypad = true
      self.timeout = REFRESH_RATE * 1000

      init_pair(1, COLOR_BLACK, COLOR_WHITE)

      loop do
        render

        case getch
        when 'q'
          break

        when Key::LEFT
          sort_next(-1)

        when Key::RIGHT
          sort_next(+1)

        when Key::UP, Key::DOWN
          sort_inverse
        end
      end

    rescue Interrupt
    ensure
      close_screen
    end

    protected
    def fetch
      @api.ip_traffic_monitor.list(
          order: "#{@sort_desc ? '-' : ''}#{@sort_param}",
          meta: {includes: 'ip_address'}
      )
    end

    def render
      t = Time.now

      setpos(0, 0)
      addstr("#{File.basename($0)} ip_traffic top - #{t.strftime('%H:%M:%S')}, ")
      addstr("next update at #{(t + REFRESH_RATE).strftime('%H:%M:%S')}, ")
      addstr("unit: #{@opts[:unit]} per second")
     
      fmt = "%-30s #{Array.new(@opts[:params].count, '%10s').join(' ')}"

      attron(color_pair(1))
      setpos(2, 0)

      header = sprintf(
          fmt,
          'IP Address',
          *param_titles,
      )
      addstr(header + (' ' * (cols - header.size)) + "\n")
      attroff(color_pair(1))

      i = 3
      fetch.each do |data|
        setpos(i, 0)
        print_row(data)
        i += 1
      end

      refresh
    end

    def param_titles
      @opts[:params].map do |v|
        v.to_s.split('_').map do |p|
          if @opts[:unit] == :bits
            p.gsub(/bytes/, 'bits').capitalize

          else
            p.capitalize
          end
        end.join('')
      end
    end

    def print_row(data)
      addstr(sprintf('%-30s', data.ip_address.addr))

      @opts[:params].each do |p|
        attron(A_BOLD) if p == @sort_param
        addstr(sprintf(' %10s', unitize(data.send(p), data.delta)))
        attroff(A_BOLD) if p == @sort_param
      end
    end

    def unitize(n, delta)
      if @opts[:unit] == :bytes
        per_s = n / delta.to_f
      else
        per_s = n * 8 / delta.to_f
      end

      bits = 39
      units = %i(T G M K)

      units.each do |u|
        threshold = 2 << bits

        return "#{(per_s / threshold).round(2)}#{u}" if per_s >= threshold

        bits -= 10
      end

      per_s.to_s
    end

    def sort_next(n)
      cur_i = @opts[:params].index(@sort_param)
      next_i = cur_i + n
      return unless @opts[:params][next_i]

      @sort_param = @opts[:params][next_i]
    end

    def sort_inverse
      @sort_desc = !@sort_desc
    end
  end
end
