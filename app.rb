require 'dotenv'
require 'sinatra'
require 'messagebird'
require 'mongo'
require 'json'

set :root, File.dirname(__FILE__)

mongo_client = Mongo::Client.new('mongodb://localhost:27017/myproject')
DB = mongo_client.database

#  Load configuration from .env file
Dotenv.load if Sinatra::Base.development?

# Load and initialize MesageBird SDK
client = MessageBird::Client.new(ENV['MESSAGEBIRD_API_KEY'])

# Handle incoming webhooks
post '/webhook' do
  request.body.rewind
  request_payload = JSON.parse(request.body.read)

  # Read input sent from MessageBird
  number = request_payload['originator']
  text = request_payload['body'].downcase

  # Find subscriber in our database
  subscribers = DB[:subscribers]
  doc = subscribers.find(number: number).first

  if doc.nil? && text == 'subscribe'
    # The user has sent the "subscribe" keyword
    # and is not stored in the database yet, so
    # we add them to the database.
    doc = {
      number: number,
      subscribed: true
    }
    subscribers.insert_one(doc)

    # Notify the user
    client.message_create(ENV['MESSAGEBIRD_ORIGINATOR'], [number], 'Thanks for subscribing to our list! Send STOP anytime if you no longer want to receive messages from us.')
  end

  if !doc.nil? && doc["subscribed"] == false && text == 'subscribe'
    # The user has sent the "subscribe" keyword
    # and was already found in the database in an
    # unsubscribed state. We resubscribe them by
    # updating their database entry.
    subscribers.update_one({ 'number' => number }, { '$set' => { 'subscribed' => true } })

    # Notify the user
    client.message_create(ENV['MESSAGEBIRD_ORIGINATOR'], [number], 'Thanks for re-subscribing to our list! Send STOP anytime if you no longer want to receive messages from us.')
  end

  if !doc.nil? && doc["subscribed"] == true && text == 'stop'
    # The user has sent the "stop" keyword, indicating
    # that they want to unsubscribe from messages.
    # They were found in the database, so we mark
    # them as unsubscribed and update the entry.
    subscribers.update_one({ 'number' => number }, { '$set' => { 'subscribed' => false } })

    # Notify the user
    client.message_create(ENV['MESSAGEBIRD_ORIGINATOR'], [number], 'Sorry to see you go! You will not receive further marketing messages from us.')
  end

  # Return any response, MessageBird won't parse this
  status 200
  body ''
end

get '/' do
  # Get number of subscribers to show on the form
  subscribers = DB[:subscribers]

  count = subscribers.count(subscribed: true)

  return erb :home, locals: { count: count }
end

post '/send' do
  # Read input from user
  message = params['message']

  # Get number of subscribers to show on the form
  subscribers = DB[:subscribers]

  docs = subscribers.find(subscribed: true)

  recipients = []
  count = 0

  # Collect all numbers
  docs.each do |doc|
    recipients.push(doc["number"])
    count += 1
    if count == docs.count || count % 50 == 0
      # We have reached either the end of our list or 50 numbers,
      # which is the maximum that MessageBird accepts in a single
      # API call, so we send the message and then, if any numbers
      # are remaining, start a new list
      client.message_create(ENV['MESSAGEBIRD_ORIGINATOR'], recipients, message)
      recipients = []
    end
  end

  return erb :sent, locals: { count: count }
end
