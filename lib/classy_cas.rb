require 'rubygems'
require 'bundler'
Bundler.require
# Bundler.require doesn't seem to be pulling this in when used as gem...
require 'sinatra'
require 'redis'
require 'nokogiri'
require 'rack'
require 'rack-flash'
require 'warden'

if RUBY_VERSION < "1.9"
  require 'backports'
  require 'system_timer'
end

require 'addressable/uri'

require_relative 'ticket'
require_relative 'login_ticket'
require_relative 'proxy_ticket'
require_relative 'service_ticket'
require_relative 'ticket_granting_ticket'
require_relative 'strategies'

module ClassyCAS

  module Helper; protected

    NAMESPACE = {'xmlns:cas' => 'http://www.yale.edu/tp/cas'}
    TRUEs     = [ true, 'true', '1', 1 ]
    URI       = Addressable::URI

    def append_user_info(username, builder)
      # override to add user info back to client applications
    end

    def render_login
      erb :login
    end
    def render_logged_in
      erb :logged_in
    end

    def has(key)
      proc do |params|
        boolean = TRUEs.include? params[key]
        instance_variable_set :"@#{ key }", boolean
      end
    end

    def create_service_ticket
      st = ServiceTicket.create! @service_url, sso_session.username, settings.redis

      service_url  = URI.parse @service_url
      query_values = service_url.query_values || {}
      service_url.query_values = query_values.merge :ticket => st.ticket

      redirect service_url.to_s, 303
    end

    def renew_login
      @login_ticket = LoginTicket.create! settings.redis
      render_login
    end
    def gateway_login
      @service_url = params[:service]

      return renew_login unless @service_url
      return redirect(@service_url, 303) unless sso_session

      create_service_ticket
    end
    def service_login
      @service_url = params[:service]

      return renew_login unless sso_session
      return render_logged_in unless @service_url

      create_service_ticket
    end

    def validate
      service_url, ticket = params[:service], params[:ticket]
      # proxy_gateway = params[:pgtUrl]
      # renew = params[:renew]

      unless service_url && ticket
        validation_error :request
      end
      unless service_ticket
        validation_error :ticket, "ticket #{ ticket } not recognized"
      end
      unless service_ticket.valid_for_service? service_url
        validation_error :service
      end

      validation_success service_ticket.username
    end

    def login
      username, password = params[:username], params[:password]
      service_url, warn  = params[:service], TRUEs.include?( params[:warn] )

      # Spec is undefined about what to do without these params, so redirecting to credential requestor
      redirect '/login', 303 unless username && password && login_ticket

      # Failures will throw back to self, which we've registered with Warden to handle login failures
      warden.authenticate! :scope => :cas, :action => 'unauthenticated'

      tgt    = TicketGrantingTicket.create! username, settings.redis
      cookie = tgt.to_cookie request.host
      response.set_cookie(*cookie)

      if service_url && !warn
        st = ServiceTicket.create! service_url, username, settings.redis
        st.save! settings.redis

        redirect "#{ service_url }?ticket=#{ st.ticket }", 303
      else
        render_logged_in
      end
    end

    def destroy_sso
      @sso_session.destroy! settings.redis
      response.delete_cookie(*sso_session.to_cookie(request.host))
      warden.logout :cas
    end

    def logout
      @url = params[:url]

      destroy_sso if sso_session

      @login_ticket = LoginTicket.create! settings.redis
      @logout       = true

      render_login
    end

    def warden
      @warden ||= request.env['warden']
    end

    def sso_session
      @sso_session ||= TicketGrantingTicket.validate request.cookies['tgt'], settings.redis
    end
    def ticket_granting_ticket
      @ticket_granting_ticket ||= sso_session
    end
    def login_ticket
      @login_ticket ||= LoginTicket.validate! params[:lt], settings.redis
    end
    def service_ticket
      @service_ticket ||= ServiceTicket.find! params[:ticket], settings.redis
    end

    def render_service_response(&block)
      content_type :xml

      Nokogiri::XML::Builder.new { |xml|
        xml.serviceResponse(NAMESPACE) { yield xml }
      }.to_xml
    end

    def validation_error(code, message = '')
      halt 200, render_service_response { |xml|
        xml.parent.namespace = xml.parent.namespace_definitions.first
        xml['cas'].authenticationFailure message, :code => "invalid_#{ code }".upcase
      }
    end

    def validation_success(username)
      render_service_response do |xml|
        xml.parent.namespace = xml.parent.namespace_definitions.first

        xml['cas'].authenticationSuccess do
          xml['cas'].user username
          append_user_info username, xml
        end
      end
    end

  end

  module Extension

    def self.registered(base)
      unless base.respond_to? :redis
        base.set :redis, lambda { Redis.new }
      end
      unless base.respond_to? :client_sites
        base.set :client_sites, %w[ http://localhost:3001 http://localhost:3002 ]
      end

      base.helpers Helper

      base.get('/') { redirect '/login' }
      base.get('/login') do
        case params
        when has(:renew)
          renew_login
        when has(:gateway)
          gateway_login
        else
          service_login
        end
      end
      base.post('/login') { login }
      base.get(%r'(proxy|service)Validate') { validate }
      base.get('/logout') { logout }

      warden_strategies = if base.respond_to? :warden_strategies
        base.warden_strategies
      else
        { :strategies => [:simple], :action => 'login' }
      end

      base.use Warden::Manager do |manager|
        manager.failure_app   = base
        manager.default_scope = :cas
        manager.scope_defaults  :cas, warden_strategies
      end
    end

  end

  class Server < Sinatra::Base
    register Extension

    LOGOUT_MSG = 'The application you just logged out of has provided a link it would like you to follow. Please <a href="%s">click here</a> to access <a href="%s">%s</a>'

    configure(:development) { set :dump_errors }

    set :root,   File.dirname(__FILE__)
    set :public, File.expand_path('../public', root)

    use Rack::Session::Cookie
    use Rack::Flash, :accessorize => [:notice, :error]

    def destroy_sso
      super

      flash.now[:notice] = 'Logout Successful.'
      flash.now[:notice] += LOGOUT_MSG % [ @url, @url, @url ] if @url
    end

  end
end
