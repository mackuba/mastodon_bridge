#!/usr/bin/env ruby

environment = ENV['RACK_ENV'] || 'development'

require 'bundler/setup'
require 'didkit'
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

  before do
    @config = File.exist?('config.yml') ? YAML.load(File.read('config.yml')) : { 'users' => {}}

    @jwt_data = extract_jwt_data

    if @jwt_data && @jwt_data['sub']
      @user_data = @config['users'][@jwt_data['sub']]
    end
  end

  def get_mastodon_timeline
    access_token = @user_data['access_token']
    server = @user_data['mastodon_handle'].split('@').last

    query = {}
    query['limit'] = params['limit'] if params['limit']

    query['limit'] = 20

    response = Net::HTTP.get_response(
      URI("https://#{server}/api/v1/timelines/home?" + URI.encode_www_form(query)),
      { 'Authorization' => "Bearer #{access_token}" }
    )

    if response.code.to_i != 200
      raise "Invalid response: #{response.code} #{response.body}"
    end

    puts "Mastodon response:"
    puts response.body
    json = JSON.parse(response.body)
    posts = json.map { |x| convert_mastodon_post(x) }

    puts "Returning:"
    puts JSON.generate(feed: posts)

    [200, { "content-type" => "application/json; charset=utf-8" }, JSON.generate(feed: posts)]
  end

  def convert_mastodon_post(json)
    json = json['reblog'] || json
    virtual_did = "did:mstdn:#{json['account']['id']}"
    virtual_handle = json['account']['acct'].gsub('@', '.').gsub('_', '-').downcase

    if virtual_handle !~ /\./
      virtual_handle += "." + @user_data['mastodon_handle'].split('@').last
    end

    {
      post: {
        uri: "at://#{virtual_did}/app.bsky.feed.post/#{json['id']}",
        cid: "bafyreieg6naxuximr5hprhfb26z3mdpzvoztswo6pjrpbze7rngld4457y",
        author: {
          did: virtual_did,
          handle: virtual_handle,
          displayName: json['account']['display_name'],
          avatar: json['account']['avatar_static'],
          viewer: {
            muted: false,
            blockedBy: false
          },
          labels: []
        },
        record: {
          '$type': "app.bsky.feed.post",
          createdAt: json['created_at'],
          langs: [json['language']].compact,
          text: json['content'].gsub(/<.+?>/, '')[0...300]
        },
        replyCount: json['replies_count'],
        repostCount: json['reblogs_count'],
        likeCount: json['favourites_count'],
        indexedAt: json['created_at'],
        viewer: {},
        labels: []
      }
    }
  end

  get "/xrpc/app.bsky.feed.getFeed" do
    if params['feed'] == 'at://did:plc:oio4hkxaop4ao4wz2pp3f4cr/app.bsky.feed.generator/mastodon'
      if @user_data
        get_mastodon_timeline
      else
        halt 401
      end
    else
      pass
    end
  end

  get /.*/ do
    headers = extract_request_headers

    if @jwt_data
      puts "[GET:JWT_DATA] #{@jwt_data['sub'].inspect}"
    else
      puts "[GET:JWT_DATA] <no data>"
    end

    if @jwt_data && @user_data
      endpoint = @user_data['pds']
    elsif @jwt_data
      halt 401
    else
      endpoint = 'https://bsky.social'
    end

    url = URI(endpoint + request.fullpath)
    get = Net::HTTP::Get.new(url, headers)

    puts "[GET:URL] #{url}"
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
    request_body = request.body.read
    content_type = request.content_type

    if @jwt_data
      puts "[POST:JWT_DATA] #{@jwt_data['sub'].inspect}"
    else
      puts "[POST:JWT_DATA] <no data>"
    end

    if @jwt_data && @user_data
      endpoint = @user_data['pds']
    elsif @jwt_data
      halt 401
    elsif request_body && content_type.start_with?('application/json') && (id = JSON.parse(request_body)['identifier'])
      if id =~ /.+@.+/
        endpoint = 'https://bsky.social'
      elsif id =~ /^did:/
        endpoint = DID.new(id).get_document.pds_endpoint
      else
        endpoint = DID.resolve_handle(id).get_document.pds_endpoint
      end
    else
      endpoint = 'https://bsky.social'
    end

    url = URI(endpoint + request.fullpath)
    post = Net::HTTP::Post.new(url, headers)
    post.body = request_body
    post.content_type = content_type

    puts "[POST:URL] #{url}"
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
