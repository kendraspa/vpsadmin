class UserPayment < ActiveRecord::Base
  belongs_to :incoming_payment
  belongs_to :user
  belongs_to :accounted_by, class_name: 'User'

  validates :user_id, :amount, :from_date, :to_date, presence: true

  def self.create!(attrs)
    payment = new(attrs)
    payment.amount = payment.incoming_payment.amount if attrs[:incoming_payment]
    payment.accounted_by = ::User.current
    monthly = payment.user.user_account.monthly_payment

    if payment.amount % monthly != 0
      payment.errors.add(
          :amount,
          "not a multiple of the monthly payment (#{monthly})"
      )
      raise ActiveRecord::RecordInvalid, payment
    end

    VpsAdmin::API::Plugins::Payments::TransactionChains::Create.fire(payment)
  end

  def received_amount
    return amount unless incoming_payment_id
    incoming_payment.src_amount || amount
  end

  def received_currency
    return SysConfig.get(:plugin_payments, :default_currency) unless incoming_payment_id
    incoming_payment.src_currency || incoming_payment.currency
  end
end
