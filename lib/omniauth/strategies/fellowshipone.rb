require 'omniauth-oauth'
require 'multi_json'
require 'oauth'

module OmniAuth
  module Strategies

    # Custom request token used to override the request for the access token
    # to allow us to grab the authenticated user URI from the Content-Location
    # response header.
    #
    # Adapted from OAuth::RequestToken

    class FellowshipOneRequestToken < ::OAuth::RequestToken

      # Intercept the get_access_token call so we can
      # * override the token_request call to make the token request reponse headers accessible
      # * use the request response to grab the Content-Location header
      #
      # Adapted from OAuth::RequestToken::get_access_token

      def get_access_token(options = {}, *arguments)

        cons = consumer
        cons.instance_eval do
          # Re-write token_request method to gain access to the response
          # (accessible via token_request_response)
          #
          # Adapted from OAuth::Consumer::token_request

          def token_request(http_method, path, token = nil, request_options = {}, *arguments)
            @tr_response = request(http_method, path, token, request_options, *arguments)
            case @tr_response.code.to_i

            when (200..299)
              if block_given?
                yield @tr_response.body
              else
                # symbolize keys
                # TODO this could be considered unexpected behavior; symbols or not?
                # TODO this also drops subsequent values from multi-valued keys
                CGI.parse(@tr_response.body).inject({}) do |h,(k,v)|
                  h[k.strip.to_sym] = v.first
                  h[k.strip]        = v.first
                  h
                end
              end
            when (300..399)
              # this is a redirect
              uri = URI.parse(@tr_response.header['location'])
              @tr_response.error! if uri.path == path # careful of those infinite redirects
              self.token_request(http_method, uri.path, token, request_options, arguments)
            when (400..499)
              raise OAuth::Unauthorized, @tr_response
            else
              @tr_response.error!
            end
          end

          # provide access to response
          def token_request_response
            @tr_response
          end
        end

        # now call token_request just like OAuth::RequestToken would
        response = cons.token_request(cons.http_method, (cons.access_token_url? ? cons.access_token_url : cons.access_token_path), self, options, *arguments)
        access_token = ::OAuth::AccessToken.from_hash(cons, response)

        # this is where we differ: we grab the authenticated user URI from
        # "Content-Location", which is where FellowshipOne API returns the user information

        # TODO: remove hack for invalid staging area URI
        # access_token.params[:authenticated_user_uri] = cons.token_request_response["Content-Location"].sub(/-internal/, '').sub(/^http:/, 'https:')
        # correct code:
        access_token.params[:authenticated_user_uri] = cons.token_request_response["Content-Location"]
        access_token
      end
    end # FellowshipOneRequestToken

    # The FellowshipOne strategey
    #
    # This strategy requires the church_code be a part of the OmniAuth provider
    # URL as a parameter, as in:
    #
    # /users/auth/:provider?church_code=demo

    class FellowshipOne < OmniAuth::Strategies::OAuth

      option :name, 'fellowship_one'
      option :client_options, {:request_token_path => '/v1/Tokens/RequestToken',
                               :access_token_path  => '/v1/Tokens/AccessToken',
                               :authorize_path => '/v1/PortalUser/Login'}
      # TODO: :proxy => '.......'

      uid { raw_info['@id'] }

      info do
        {
          :first => raw_info['firstName'],
          :last => raw_info['lastName'],
          :preferred => raw_info['goesByName'],
          :church_code => access_token.consumer.options[:church_code]
        }
      end

      extra do
        { :raw_info => raw_info }
      end

      # read the authenticated user information. If this fails, the failure reason
      # will show up as "Invalid response".

      def raw_info
        @raw_info ||= MultiJson.decode(access_token.get(access_token.params[:authenticated_user_uri] + '.json').body)['person']
      rescue ::Errno::ETIMEDOUT
        raise ::Timeout::Error
      end

      # Override consumer construction so we can grab the church_code from the
      # request parameters to fully construct the URL for the site, replacing
      # %CC.  We also save the church code in the consumer so we can make it
      # part of the access token later.
      #
      # Adapted from OmniAuth::Strategies::OAuth::consumer

      def consumer
        # update site with the real URL based on the church name received via
        # the omniauth config or the request params
        church_code = request.params['church_code'] || options.church_code
        site = church_code ? options.site.sub(/%CC/, church_code) : options.site
        client_options = options.client_options.merge(:site => site)
        consumer = ::OAuth::Consumer.new(options.consumer_key, options.consumer_secret, client_options)
        consumer.options[:church_code] = church_code
        consumer.http.open_timeout = options.open_timeout if options.open_timeout
        consumer.http.read_timeout = options.read_timeout if options.read_timeout
        consumer
      end

      # Override the callback phase so that we can use our own request token
      # (FellowshipOneRequestToken) instead of OAuth::RequestToken.
      #
      # Adapted from OmniAuth::Strategies::OAuth::callback_phase

      def callback_phase
        raise OmniAuth::NoSessionError.new("Session Expired") if session['oauth'].nil?

        request_token = FellowshipOneRequestToken.new(consumer, session['oauth'][name.to_s].delete('request_token'), session['oauth'][name.to_s].delete('request_secret'))

        opts = {}
        if session['oauth'][name.to_s]['callback_confirmed']
          opts[:oauth_verifier] = request['oauth_verifier']
        else
          opts[:oauth_callback] = callback_url
        end

        @access_token = request_token.get_access_token(opts)
        # IMPORTANT: DO NOT REMOVE THIS! WE DO NOT WANT TO CALL
        # OmniAuth::Strategies::OAuth::callback_phase here! So, we must copy
        # OmniAuth::Strategy::callback_phase here

        # super
        self.env['omniauth.auth'] = auth_hash
        call_app!
      rescue ::Timeout::Error => e
        fail!(:timeout, e)
      rescue ::Net::HTTPFatalError, ::OpenSSL::SSL::SSLError => e
        fail!(:service_unavailable, e)
      rescue ::OAuth::Unauthorized => e
        fail!(:invalid_credentials, e)
      rescue ::NoMethodError, ::MultiJson::DecodeError => e
        fail!(:invalid_response, e)
      rescue ::OmniAuth::NoSessionError => e
        fail!(:session_expired, e)
      end

    end # FellowshipOne

  end
end
