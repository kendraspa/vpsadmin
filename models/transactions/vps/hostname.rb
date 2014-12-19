module Transactions::Vps
  class Hostname < ::Transaction
    t_name :vps_hostname
    t_type 2004

    def params(vps, orig, hostname)
      self.t_vps = vps.vps_id
      self.t_server = vps.vps_server

      {
          hostname: hostname,
          original: orig
      }
    end
  end
end
