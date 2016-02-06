module Transactions::OutageWindow
  class InOrFail < ::Transaction
    t_name :outage_window_in_or_fail
    t_type 2102
    queue :general

    # @param vps [::Vps]
    # @param reserve_time [Integer] number of minutes that must be left in the window
    def params(vps, reserve_time)
      self.t_vps = vps.vps_id
      self.t_server = vps.vps_server

      windows = []

      vps.vps_outage_windows.where(is_open: true).order('weekday').each do |w|
        windows << {
            weekday: w.weekday,
            opens_at: w.opens_at,
            closes_at: w.closes_at,
        }
      end

      {
          windows: windows,
          reserve_time: reserve_time,
      }
    end
  end
end
