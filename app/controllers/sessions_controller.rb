# frozen_string_literal: true

class SessionsController < ApplicationController
  before_action :set_auth, only: %i[complete ticket signup]
  skip_forgery_protection only: :create # Apple sends POST to /auth/apple/callback with no CSRF token

  def create
    auth = request.env["omniauth.auth"].slice("provider", "uid", "info")
    Rails.logger.info(auth) if ENV["VERBOSE_LOGGING"]
    authorization =
      Authorization.find_by(provider: auth["provider"], uid: auth["uid"])
    if authorization.present?
      sign_in(authorization.user)

      redirect_to notices_path,
                  notice:
                    t(
                      "sessions.welcome_back",
                      nickname: authorization.user.name,
                    )
    elsif signed_in?
      current_user.authorizations.find_or_create_by!(
        provider: auth["provider"],
        uid: auth["uid"],
      )

      redirect_to edit_user_path,
                  notice:
                    t("sessions.connected", provider: auth["provider"].humanize)
    else
      session[:auth_path] = notices_path
      session[:auth_data] = auth

      redirect_to auth["provider"] == "email" ? ticket_path : signup_path
    end
  end

  def validation
    user = User.find_by!(token: params[:token])
    user.validate!

    redirect_to notices_path, notice: t("sessions.validation_successful")
  end

  def destroy
    sign_out if signed_in?

    redirect_to root_path, notice: flash[:notice] || t("sessions.bye")
  end

  def destroy_alias
    sign_out_alias if signed_in_alias?

    redirect_to root_path, notice: flash[:notice] || t("sessions.bye")
  end

  def failure
    Rails.logger.warn("oauth failed: #{params[:message]}")
    redirect_to root_path,
                alert:
                  "#{t('sessions.ups_something_went_wrong')} (#{params[:message]})"
  end

  def offline_login
    session.destroy
    user = User.find_by_nickname!(params[:nickname])
    sign_in(user)

    redirect_to edit_user_path, notice: "Offline Login for #{user.nickname}!"
  end

  def email; end

  def email_signup
    email = normalize_email(params[:email])
    if email.present?
      token = Token.generate(email)
      user = User.find_by_email(email)
      if user.present?
        UserMailer.login_link(user, token).deliver_later

        redirect_to root_path, notice: t("users.login_link", email:)
      else
        UserMailer.signup_link(email, token).deliver_later

        redirect_to root_path, notice: t("users.signup_link", email:)
      end
    else
      flash.now[:alert] = "Bitte gebe eine E-Mail-Adresse ein!"

      render :email
    end
  end

  def signup
    email = normalize_email(@auth["info"]["email"])
    check_existing_user(email)

    nickname = @auth["info"]["nickname"]
    @user = User.new(nickname:)
    @user.email = email
  end

  def ticket
    email = normalize_email(@auth["info"]["email"])
    if check_existing_user(email)
      render :email
    else
      redirect_to signup_path
    end
  end

  def complete
    attributes = user_params
    email = normalize_email(session[:email_auth_address])
    if email.present?
      attributes[:email] = email
      attributes[:validation_date] = Time.now
    end
    @user = User.new(attributes)
    @user.authorizations.build provider: @auth["provider"], uid: @auth["uid"]

    if @user.save
      session.delete(:auth_data)
      UserMailer.signup(@user).deliver_later
      sign_in(@user)

      redirect_to session.delete(:auth_path),
                  notice: t("sessions.welcome", nickname: @user.nickname)
    else
      email = normalize_email(params[:user][:email])
      check_existing_user(email)

      render :signup
    end
  rescue ActiveRecord::RecordNotUnique
    # user should already be signed in from a concurrent request
    session.delete(:auth_data)
    redirect_to session.delete(:auth_path),
                notice: t("sessions.welcome", nickname: @user.nickname)
  end

  def disconnect
    authorization = current_user.authorizations.find_by!(provider: params[:provider])
    authorization.destroy!

    redirect_back_or_to(edit_user_path(current_user), notice: "Verknüpfung wurde entfernt")
  end

  private

  def user_params
    params.require(:user).permit(
      :nickname,
      :email,
      :phone,
      :name,
      :street,
      :zip,
      :city,
    )
  end

  def normalize_email(email)
    email.to_s.strip.downcase
  end

  def set_auth
    @auth = session[:auth_data]
    _404("no auth available in session") if @auth.blank?
  end

  def check_existing_user(email)
    existing_user = User.find_by_email(email)
    if email.present? && existing_user.present?
      providers = existing_user.authorizations.map(&:provider)
      flash.now[:alert] = t(
        "sessions.existing_user",
        email:,
        providers: providers.to_sentence,
      )
    end
  end
end
