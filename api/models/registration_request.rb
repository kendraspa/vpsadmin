class RegistrationRequest < UserRequest
  belongs_to :os_template
  belongs_to :location
  belongs_to :language

  validates :login, :full_name, :email, :address, :year_of_birth, :os_template_id,
            :location_id, :currency, :language_id, presence: true
  validates :login, format: {
      with: /\A[a-zA-Z0-9\.\-]{2,63}\z/,
      message: 'not a valid login',
  }
  validates :full_name, length: {minimum: 2}
  validates :email, format: {
      with: /\A[^@]+@[a-zA-Z0-9_-]+\.[a-z]+\z/,
      message: 'not a valid e-mail address',
  }
  validate :check_login
  validate :check_org

  def user_mail
    email
  end

  def user_language
    language
  end

  def type_name
    'registration'
  end

  def label
    if org_name
      "#{org_name}, #{full_name}"

    else
      full_name
    end
  end

  def approve(chain, params)
    new_user = ::User.new(
        login: login,
        address: address,
        email: email,
        language: language,
        level: 2,
        mailer_enabled: true,
    )
    new_user.set_password(generate_password)

    if org_name
      new_user.full_name = "#{org_name} (ID #{org_id}), #{full_name}"

    else
      new_user.full_name = full_name
    end

    chain.use_chain(TransactionChains::User::Create, args: [
        new_user,
        params[:create_vps],
        params[:create_vps] && (params[:node] || ::Node.pick_by_location(location)),
        os_template,
    ])
  end

  protected
  def generate_password
    chars = ('a'..'z').to_a + ('A'..'Z').to_a + (0..9).to_a
    (0..11).map { chars.sample }.join
  end

  def check_login
    return if persisted?
    user = ::User.exists?(login: login)
    req = self.class.exists?(
        state: self.class.states[:awaiting],
        login: login,
    )

    errors.add(:login, "is taken") if user || req
  end

  def check_org
    if org_name && !org_id
      errors.add(:org_id, 'must be set when org_name is set')
    end
  end
end
