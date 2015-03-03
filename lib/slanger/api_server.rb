# encoding: utf-8
require 'sinatra/base'
require 'signature'
require 'json'
require 'active_support/core_ext/hash'
require 'eventmachine'
require 'em-hiredis'
require 'rack'
require 'fiber'
require 'rack/fiber_pool'

module Slanger
  class ApiServer < Sinatra::Base
    use Rack::FiberPool
    set :raise_errors, lambda { false }
    set :show_exceptions, false

    # Respond with HTTP 401 Unauthorized if request cannot be authenticated.
    error(Signature::AuthenticationError) { |c| halt 401, "401 UNAUTHORIZED\n" }

    post '/apps/:app_id/events' do
      authenticate

      # Event and channel data are now serialized in the JSON data
      # So, extract and use it
      data = JSON.parse(request.body.read.tap{ |s| s.force_encoding('utf-8')})

      # Send event to each channel
      data["channels"].each { |channel| publish(channel, data['name'], data['data']) }

      status 202
      return {}.to_json
    end

    get '/apps/:app_id/channels' do
      status 200
      return { channels: Channel.occupied }.to_json
    end

    get '/apps/:app_id/channels/:channel_id' do
      channel = Channel.from(params[:channel_id])
      status 200

      if channel.ids.present?
        return { user_count: channel.ids.size }.to_json
      else
        return { user_count: '0' }.to_json
      end
    end

    get '/apps/:app_id/channels/:channel_id/users' do
      channel = Channel.from(params[:channel_id])
      status 200

      if channel.subscribers.present?
        return { users: channel.subscribers }.to_json
      else
        return { users: nil }.to_json
      end
    end

    post '/apps/:app_id/channels/:channel_id/events' do
      authenticate

      publish(params[:channel_id], params['name'],  request.body.read.tap{ |s| s.force_encoding('utf-8') })

      status 202
      return {}.to_json
    end

    def payload(channel, event, data)
      {
        event:     event,
        data:      data,
        channel:   channel,
        socket_id: params[:socket_id]
      }.select { |_,v| v }.to_json
    end

    def authenticate
      # authenticate request. exclude 'channel_id' and 'app_id' included by sinatra but not sent by Pusher.
      # Raises Signature::AuthenticationError if request does not authenticate.
      Signature::Request.new('POST', env['PATH_INFO'], params.except('captures', 'splat' , 'channel_id', 'app_id')).
        authenticate { |key| Signature::Token.new key, Slanger::Config.secret }
    end

    def publish(channel, event, data)
      Slanger::Redis.publish(channel, payload(channel, event, data))
    end
  end
end
