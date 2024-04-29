#!/usr/bin/env ruby

require 'bundler/setup'
require 'io/console'
require 'json'
require 'mastodon'
require 'net/http'
require 'uri'
require 'yaml'

config = File.exist?('config.yml') ? YAML.load(File.read('config.yml')) : {}

bsky_did = ARGV[0]
masto_handle = ARGV[1]

if bsky_did.to_s.empty? || masto_handle.to_s.empty?
  puts "Usage: #{$PROGRAM_NAME} <did> <handle@server>"
  exit 1
end

server = masto_handle.split('@').last

config['apps'] ||= {}
config['users'] ||= {}

unless config['apps'][server]
  client = Mastodon::REST::Client.new(base_url: "https://#{server}")
  response = client.create_app('bluesky_mastodon_bridge', 'urn:ietf:wg:oauth:2.0:oob', 'read:statuses read:accounts')

  config['apps'][server] = { 'client_id' => response.client_id, 'client_secret' => response.client_secret }
end

print "Email: "
email = STDIN.gets.chomp

print "Password: "
password = STDIN.noecho(&:gets).chomp
puts

url = "https://#{server}/oauth/token"

params = {
  client_id: config['apps'][server]['client_id'],
  client_secret: config['apps'][server]['client_secret'],
  grant_type: 'password',
  scope: 'read:statuses read:accounts',
  username: email,
  password: password
}

response = Net::HTTP.post_form(URI(url), params)
status = response.code.to_i

if status / 100 == 2
  json = JSON.parse(response.body)
else
  puts "Bad response: #{response}"
  exit 1
end

access_token = json['access_token']
config['users'][bsky_did] = { 'mastodon_handle' => masto_handle, 'access_token' => access_token }

response = Net::HTTP.get_response(
  URI("https://#{server}/api/v1/accounts/verify_credentials"),
  { 'Authorization' => "Bearer #{access_token}" }
)

status = response.code.to_i

if status / 100 == 2
  json = JSON.parse(response.body)
else
  puts "Bad response: #{response}"
  exit 1
end

config['users'][bsky_did]['user_id'] = json['id']

File.write('config.yml', YAML.dump(config))
