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

  def make_virtual_did(mastodon_account)
    "did:mstdn:#{mastodon_account['id']}"
  end

  def make_virtual_handle(mastodon_account)
    virtual_handle = mastodon_account['acct'].gsub('@', '.').gsub('_', '-').downcase

    if virtual_handle !~ /\./
      virtual_handle += "." + @user_data['mastodon_handle'].split('@').last
    end

    virtual_handle
  end

  def mastodon_post_as_record(json)
    {
      '$type': "app.bsky.feed.post",
      createdAt: json['created_at'],
      langs: ['en'],
      text: json['content'].gsub(/<.+?>/, '')[0...300]
    }
  end

  def convert_mastodon_post(json)
    if json['reblog']
      reposter = json
      json = json['reblog']
    end

    virtual_did = make_virtual_did(json['account'])
    virtual_handle = make_virtual_handle(json['account'])

    post_view = {
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
        record: mastodon_post_as_record(json),
        replyCount: json['replies_count'],
        repostCount: json['reblogs_count'],
        likeCount: json['favourites_count'],
        indexedAt: json['created_at'],
        viewer: {},
        labels: []
      }
    }

    if reposter
      rt_virtual_did = make_virtual_did(reposter['account'])
      rt_virtual_handle = make_virtual_handle(reposter['account'])

      post_view[:reason] = {
        '$type': "app.bsky.feed.defs#reasonRepost",
        by: {
          did: rt_virtual_did,
          handle: rt_virtual_handle,
          displayName: reposter['account']['display_name'],
          avatar: reposter['account']['avatar_static'],
          viewer: {
            muted: false,
            blockedBy: false
          },
          labels: []
        },
        indexedAt: reposter['created_at']
      }
    end

    post_view
  end

  def get_mastodon_post(id)
    access_token = @user_data['access_token']
    server = @user_data['mastodon_handle'].split('@').last

    response = Net::HTTP.get_response(
      URI("https://#{server}/api/v1/statuses/#{id}"),
      { 'Authorization' => "Bearer #{access_token}" }
    )

    if response.code.to_i != 200
      raise "Invalid response: #{response.code} #{response.body}"
    end

    json = JSON.parse(response.body)
    virtual_did = make_virtual_did(json['account'])

    post_view = {
      uri: "at://#{virtual_did}/app.bsky.feed.post/#{json['id']}",
      cid: "bafyreieg6naxuximr5hprhfb26z3mdpzvoztswo6pjrpbze7rngld4457y",
      value: mastodon_post_as_record(json)
    }

    [200, { "content-type" => "application/json; charset=utf-8" }, JSON.generate(post_view)]
  end

  def make_mastodon_reply(json)
    parent_id = json['record']['reply']['parent']['uri'].split('/').last
    text = json['record']['text']

    access_token = @user_data['access_token']
    server = @user_data['mastodon_handle'].split('@').last

    url = URI("https://#{server}/api/v1/statuses")
    post = Net::HTTP::Post.new(url, { 'Authorization' => "Bearer #{access_token}" })
    post.content_type = 'application/json'
    post.body = JSON.generate({
      status: text,
      in_reply_to_id: parent_id      
    })

    puts "[POST:URL] #{url}"
    puts "[POST:HEADERS] #{post.each_header.inspect}"
    puts "[POST:BODY] #{post.body.inspect}"

    response = Net::HTTP.start(post.uri.hostname, post.uri.port, use_ssl: true) do |http|
      http.request(post)
    end

    if response.code.to_i != 200
      raise "Invalid response: #{response.code} #{response.body}"
    end

    puts "Mastodon response:"
    puts response.body
    json = JSON.parse(response.body)

    virtual_did = make_virtual_did(json['account'])
    at_uri = "at://#{virtual_did}/app.bsky.feed.post/#{json['id']}"
    bsky_response = { uri: at_uri, cid: "bafyreieg6naxuximr5hprhfb26z3mdpzvoztswo6pjrpbze7rngld4457y" }

    [200, { "content-type" => "application/json; charset=utf-8" }, JSON.generate(bsky_response)]
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

  get "/xrpc/com.atproto.repo.getRecord" do
    if params['collection'] == 'app.bsky.feed.post' && params['repo'].start_with?('did:mstdn')
      get_mastodon_post(params['rkey'])
    else
      pass
    end
  end

  post "/xrpc/com.atproto.repo.createRecord" do
    json = JSON.parse(request.body.read)

    if json['collection'] == 'app.bsky.feed.post'
      if json['record']['reply'] && json['record']['reply']['parent']['uri'].start_with?('at://did:mstdn')
        make_mastodon_reply(json)
      else
        request.body.rewind
        pass
      end
    else
      request.body.rewind
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
