module S3

  # Class responsible for handling connections to amazon hosts
  class Connection
    include Parser

    attr_accessor :access_key_id, :secret_access_key, :use_ssl, :timeout, :debug
    alias :use_ssl? :use_ssl

    # Creates new connection object.
    #
    # ==== Options
    # * <tt>:access_key_id</tt> - Access key id (REQUIRED)
    # * <tt>:secret_access_key</tt> - Secret access key (REQUIRED)
    # * <tt>:use_ssl</tt> - Use https or http protocol (false by
    #   default)
    # * <tt>:debug</tt> - Display debug information on the STDOUT
    #   (false by default)
    # * <tt>:timeout</tt> - Timeout to use by the Net::HTTP object
    #   (60 by default)
    def initialize(options = {})
      @access_key_id = options.fetch(:access_key_id)
      @secret_access_key = options.fetch(:secret_access_key)
      @use_ssl = options.fetch(:use_ssl, false)
      @debug = options.fetch(:debug, false)
      @timeout = options.fetch(:timeout, 60)
    end

    # Makes request with given HTTP method, sets missing parameters,
    # adds signature to request header and returns response object
    # (Net::HTTPResponse)
    #
    # ==== Parameters
    # * <tt>method</tt> - HTTP Method symbol, can be <tt>:get</tt>,
    #   <tt>:put</tt>, <tt>:delete</tt>
    #
    # ==== Options:
    # * <tt>:host</tt> - Hostname to connecto to, defaults
    #   to <tt>s3.amazonaws.com</tt>
    # * <tt>:path</tt> - path to send request to (REQUIRED)
    # * <tt>:body</tt> - Request body, only meaningful for
    #   <tt>:put</tt> request
    # * <tt>:params</tt> - Parameters to add to query string for
    #   request, can be String or Hash
    # * <tt>:headers</tt> - Hash of headers fields to add to request
    #   header
    #
    # ==== Returns
    # Net::HTTPResponse object -- response from the server
    def request(method, options)
      host = options.fetch(:host, HOST)
      path = options.fetch(:path)
      body = options.fetch(:body, "")
      params = options.fetch(:params, {})
      headers = options.fetch(:headers, {})

      if params
        params = params.is_a?(String) ? params : self.class.parse_params(params)
        path << "?#{params}"
      end

      path = URI.escape(path)
      request = request_class(method).new(path)

      headers = self.class.parse_headers(headers)
      headers.each do |key, value|
        request[key] = value
      end

      request.body = body

      send_request(host, request)
    end

    # Helper function to parser parameters and create single string of
    # params added to questy string
    #
    # ==== Parameters
    # * <tt>params</tt> - Hash of parameters
    #
    # ==== Returns
    # String -- containing all parameters joined in one params string,
    # i.e. <tt>param1=val&param2&param3=0</tt>
    def self.parse_params(params)
      interesting_keys = [:max_keys, :prefix, :marker, :delimiter, :location]

      result = []
      params.each do |key, value|
        if interesting_keys.include?(key)
          parsed_key = key.to_s.gsub("_", "-")
          case value
          when nil
            result << parsed_key
          else
            result << "#{parsed_key}=#{value}"
          end
        end
      end
      result.join("&")
    end

    # Helper function to change headers from symbols, to in correct
    # form (i.e. with '-' instead of '_')
    #
    # ==== Parameters
    # * <tt>headers</tt> - Hash of pairs <tt>headername => value</tt>,
    #   where value can be Range (for Range header) or any other value
    #   which can be translated to string
    #
    # ==== Returns
    # Hash of headers translated from symbol to string, containing
    # only interesting headers
    def self.parse_headers(headers)
      interesting_keys = [:content_type, :x_amz_acl, :range,
                          :if_modified_since, :if_unmodified_since,
                          :if_match, :if_none_match,
                          :content_disposition, :content_encoding,
                          :x_amz_copy_source, :x_amz_metadata_directive,
                          :x_amz_copy_source_if_match,
                          :x_amz_copy_source_if_none_match,
                          :x_amz_copy_source_if_unmodified_since,
                          :x_amz_copy_source_if_modified_since]

      parsed_headers = {}
      if headers
        headers.each do |key, value|
          if interesting_keys.include?(key)
            parsed_key = key.to_s.gsub("_", "-")
            parsed_value = value
            case value
            when Range
              parsed_value = "bytes=#{value.first}-#{value.last}"
            end
            parsed_headers[parsed_key] = parsed_value
          end
        end
      end
      parsed_headers
    end

    private

    def request_class(method)
      case method
      when :get
        request_class = Net::HTTP::Get
      when :head
        request_class = Net::HTTP::Head
      when :put
        request_class = Net::HTTP::Put
      when :delete
        request_class = Net::HTTP::Delete
      end
    end

    def port
      use_ssl ? 443 : 80
    end

    def http(host)
      http = Net::HTTP.new(host, port)
      http.set_debug_output(STDOUT) if @debug
      http.use_ssl = @use_ssl
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @use_ssl
      http.read_timeout = @timeout if @timeout
      http
    end

    def send_request(host, request)
      response = http(host).start do |http|
        host = http.address

        request['Date'] ||= Time.now.httpdate

        if request.body
          request["Content-Type"] ||= "application/octet-stream"
          request["Content-MD5"] = Base64.encode64(Digest::MD5.digest(request.body)).chomp unless request.body.empty?
        end

        request["Authorization"] = Signature.generate(:host => host,
                                                      :request => request,
                                                      :access_key_id => access_key_id,
                                                      :secret_access_key => secret_access_key)
        http.request(request)
      end

      handle_response(response)
    end

    def handle_response(response)
      case response.code.to_i
      when 200...300
        response
      when 300...600
        if response.body.nil? || response.body.empty?
          raise Error::ResponseError.new(nil, response)
        else
          code, message = parse_error(response.body)
          raise Error::ResponseError.exception(code).new(message, response)
        end
      else
        raise(ConnectionError.new(response, "Unknown response code: #{response.code}"))
      end
      response
    end
  end
end
