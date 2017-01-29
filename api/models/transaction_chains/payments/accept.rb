module VpsAdmin::API::Plugins::Payments::TransactionChains
  class Accept < ::TransactionChain
    label 'Accept'
    allow_empty

    def link_chain
      ::IncomingPayment.where(
          state: ::IncomingPayment.states[:queued],
      ).each do |income|
        begin
          u = ::User.find(income.vs.to_i)
        
        rescue ActiveRecord::RecordNotFound
          income.update!(state: ::IncomingPayment.states[:unmatched])
          next
        end

        payment = process(u, income)

        unless payment
          income.update!(state: ::IncomingPayment.states[:unmatched])
          next
        end
      end
    end

    def process(u, income)
      payment = ::UserPayment.new(
          incoming_payment: income,
          user: u,
      )
      amount = income.converted_amount

      # Break if we're unable to figure out the received amount
      return if amount.nil?

      # Break if the received amount is not a multiple of the monthly payment
      return if amount % u.user_account.monthly_payment != 0

      payment.amount = amount

      use_chain(Create, args: payment)

      payment
    end
  end
end
