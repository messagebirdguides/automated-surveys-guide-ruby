require 'dotenv'
require 'sinatra'
require 'mongo'
require 'json'
require 'net/http'
require 'uri'

set :root, File.dirname(__FILE__)

#  Load configuration from .env file
Dotenv.load if Sinatra::Base.development?

mongo_client = Mongo::Client.new('mongodb://localhost:27017/myproject')
DB = mongo_client.database

QUESTIONS = JSON.parse(File.read('questions.json'))

# Helper function to generate a "say" call flow step.
def say(payload)
  {
    action: 'say',
    options: {
      payload: payload,
      voice: 'male',
      language: 'en-US'
    }
  }
end

%i[get post].each do |method|
  send method, '/callStep' do
    # Prepare a Call Flow that can be extended
    flow = {
      title: 'Survey Call Step',
      steps: []
    }

    collection = DB[:survey_participants]

    call_id = params['callID']

    doc = collection.find(callId: call_id).first

    # Determine the next question
    question_id = doc.nil? ? 0 : doc['responses'].length + 1

    if doc.nil?
      # Create new participant database entry
      doc = {
        callId: params['callID'],
        number: params['destination'],
        responses: []
      }
      collection.insert_one(doc)
    end

    if question_id > 0
      request_payload = JSON.parse(request.body.read.to_s)

      # Unless we're at the first question, store the response
      # of the previous question
      doc['responses'].push({
        legId: request_payload['legId'],
        recordingId: request_payload['id']
      })

      collection.update_one({ 'callId' => call_id }, { '$set' => { 'responses' => doc['responses'] } })
    end

    if question_id == QUESTIONS.length
      # All questions have been answered
      flow[:steps].push(say('You have completed our survey. Thank you for participating!'))
    else
      if question_id.zero?
        # Before first question, say welcome
        flow[:steps].push(say("Welcome to our survey! You will be asked #{QUESTIONS.length} questions. The answers will be recorded. Speak your response for each and press any key on your phone to move on to the next question. Here is the first question:"))
      end

      # Ask next question
      flow[:steps].push(say(QUESTIONS[question_id]))

      # Request recording of question
      flow[:steps].push(
        action: 'record',
        options: {
          # Finish either on key press or after 10 seconds of silence
          finishOnKey: 'any',
          timeout: 10,
          # Send recording to this same call flow URL
          onFinish: "http://#{request.host}/callStep"
        }
      )
    end

    content_type :json
    flow.to_json
  end
end

get '/admin' do
  collection = DB[:survey_participants]
  docs = collection.find
  erb :participants, locals: {
    questions: QUESTIONS,
    participants: docs
  }
end

get '/play/:callId/:legId/:recordingId' do
  uri = URI.parse("https://voice.messagebird.com/calls/#{params[:callId]}/legs/#{params[:legId]}/recordings/#{params[:recordingId]}.wav")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request = Net::HTTP::Post.new(uri.request_uri)
  request['Authorization'] = "AccessKey #{ENV['MESSAGEBIRD_API_KEY']}"
  puts uri
  puts  "AccessKey #{ENV['MESSAGEBIRD_API_KEY']}"
  # stream back the contents
  stream(:keep_open) do |out|
    http.request(request) do |f|
      puts f
      f.read_body { |ch| out << ch }
    end
  end
end
