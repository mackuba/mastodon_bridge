#!/usr/bin/env ruby

environment = ENV['RACK_ENV'] || 'development'

require 'bundler/setup'
require 'net/http'
require 'sinatra/base'
require 'sinatra/reloader' if environment == 'development'
require 'yaml'

class Server < Sinatra::Base
  enable :logging
  set :port, ENV['PORT'] || 3000
  set :bind, '0.0.0.0'

  configure :development do
    register Sinatra::Reloader
  end

  def extract_request_headers
    request.each_header
      .select { |k, v| k.start_with?('HTTP_') }
      .map { |k, v| [k.gsub(/^HTTP_/, '').gsub(/_/, '-').downcase, v] }
      .reject { |k, v| k == 'host' || k == 'accept-encoding' }
      .then { |x| Hash[x] }
  end

  def extract_jwt_data
    if auth = request.env['HTTP_AUTHORIZATION']
      if auth.start_with?('Bearer ')
        token = auth[7..-1]
        JSON.parse(Base64.decode64(token.split('.')[1]))
      end
    end
  end    

  get /.*/ do
    headers = extract_request_headers

    url = "https://amanita.us-east.host.bsky.network" + request.fullpath

    if jwt_data = extract_jwt_data
      puts "[GET:JWT_DATA] #{jwt_data['sub'].inspect}"
    else
      puts "[GET:JWT_DATA] <no data>"
    end

    get = Net::HTTP::Get.new(URI(url), headers)

    puts "[GET:REQ_HEADERS] #{headers.inspect}"

    response = Net::HTTP.start(get.uri.hostname, get.uri.port, use_ssl: true) do |http|
      http.request(get)
    end

    status = response.code.to_i
    response_body = response.body
    headers = Hash[response.each_header.to_a]
    headers.delete('transfer-encoding')

    puts "[GET:RETURNING]"
    p [status, headers, response_body]

    [status, headers, response_body]
  end

  post /.*/ do
    headers = extract_request_headers

    url = "https://amanita.us-east.host.bsky.network" + request.fullpath

    if jwt_data = extract_jwt_data
      puts "[POST:JWT_DATA] #{jwt_data['sub'].inspect}"
    else
      puts "[POST:JWT_DATA] <no data>"
    end

    post = Net::HTTP::Post.new(URI(url), headers)
    post.body = request.body.read
    post.content_type = request.content_type

    puts "[POST:REQ_HEADERS] #{headers.inspect}"
    puts "[POST:REQ_BODY] #{post.body.inspect}"
    puts "[POST:REQ_EACH] #{request.each_header.inspect}"

    response = Net::HTTP.start(post.uri.hostname, post.uri.port, use_ssl: true) do |http|
      http.request(post)
    end

    status = response.code.to_i
    response_body = response.body
    headers = Hash[response.each_header.to_a]
    headers.delete('transfer-encoding')

    puts "[POST:RETURNING]"
    p [status, headers, response_body]

    if request.fullpath == '/xrpc/com.atproto.server.createSession'
      json = JSON.parse(response_body)
      json['didDoc']['service'].detect { |s| s['id'] == '#atproto_pds' }['serviceEndpoint'] = request.base_url
      response_body = JSON.generate(json)
      puts "[POST:UPDATED] #{response_body.inspect}"
    end

    [status, headers, response_body]
  end
end

if $PROGRAM_NAME == __FILE__
  Server.run!
end
