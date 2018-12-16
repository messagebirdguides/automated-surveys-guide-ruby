# Automated Voice Surveys

### ⏱ 15 min build time

## Why build automated voice surveys?

Surveys are a great way to gather feedback about a product or a service. In this MessageBird Developer Tutorial, we'll look at a company that wants to collect surveys over the phone by providing their customers a feedback number that they can call and submit their opinion as voice messages that the company's support team can listen to on a website and incorporate that feedback into the next version of the product. This team should be able to focus their attention on the input on their own time instead of having to wait and answer calls. Therefore, the feedback collection itself is fully automated.

## Getting Started

The sample application is built in Ruby using the [Sinatra framework](http://sinatrarb.com/). You can download or clone the complete source code from the [MessageBird Developer Tutorials GitHub repository](https://github.com/messagebirdguides/automated-surveys-ruby) to run the application on your computer and follow along with the tutorial. To run the sample, you will need [Ruby](https://www.ruby-lang.org/en/) and [bundler](https://bundler.io/) installed.

Let's get started by opening the directory of the sample application and running the following command to install the dependencies:

```
bundle install
```

The sample application uses [MongoDB](https://rubygems.org/gems/mongo) to provide an in-memory database for testing, so you don't need to configure an external database. As the mock loses data when you restart the application you need to replace it with a real server when you want to develop this sample into a production application.

## Designing the Call Flow

Call flows in MessageBird are sequences of steps. Each step can be a different action, such as playing an audio file, speaking words through text-to-speech (TTS), recording the caller's voice or transferring the call to another party. The call flow for this survey application alternates two types of actions: saying the question (`say` action) and recording an answer (`record` action). Other action types are not required. The whole flow begins with a short introduction text and ends on a "Thank you" note, both of which are implemented as `say` actions.

The survey application generates the call flow dynamically through Ruby code and provides it on a webhook endpoint as a JSON response that MessageBird can parse. It does not, however, return the complete flow at once. The generated steps always end on a `record` action with the `onFinish` attribute set to the same webhook endpoint URL. This approach simplifies the collection of recordings because whenever the caller provides an answer, an identifier for the recording is sent with the next webhook request. The endpoint will then store information about the answer to the question and return additional steps: either the next question together with its answer recording step or, if the caller has reached the end of the survey, the final "Thank you" note.

The sample implementation contains only a single survey. For each participant, we create a (mocked) database entry that includes a unique MessageBird-generated identifier for the call, their number and an array of responses. As the webhook is requested multiple times for each caller, once in the beginning and once for each answer they record, the length of the responses array indicates their position within the survey and determines the next step.

All questions are stored as an array in the file `questions.yml` to keep them separate from the implementation. The following statement at the top of `app.rb` loads them:

```
questions =YAML.load_file('questions.yml')
```

## Prerequisites for Receiving Calls

### Overview

Participants take part in a survey by calling a dedicated virtual phone number. MessageBird accepts the call and contacts the application on a _webhook URL_, which you assign to your number on the MessageBird Dashboard using a flow. A [webhook](https://en.wikipedia.org/wiki/Webhook) is a URL on your site that doesn't render a page to users but is like an API endpoint that can be triggered by other servers. Every time someone calls that number, MessageBird checks that URL for instructions on how to interact with the caller.

### Exposing your Development Server with ngrok

When working with webhooks, an external service like MessageBird needs to access your application, so the URL must be public. During development, though, you're typically working in a local development environment that is not publicly available. There are various tools and services available that allow you to quickly expose your development environment to the Internet by providing a tunnel from a public URL to your local machine. One of the most popular tools is [ngrok](https://ngrok.com/).

You can [download ngrok here for free](https://ngrok.com/download) as a single-file binary for almost every operating system, or optionally sign up for an account to access additional features.

You can start a tunnel by providing a local port number on which your application runs. We will run our Ruby server on port 4567, so you can launch your tunnel with this command:

```
ngrok http 4567
```

After you've launched the tunnel, ngrok displays your temporary public URL along with some other information. We'll need that URL in a minute.

Another common tool for tunneling your local machine is [localtunnel.me](https://localtunnel.me/), which you can have a look at if you're facing problems with ngrok. It works in virtually the same way but requires you to install [NPM](https://www.npmjs.com/) first.

### Getting an Inbound Number

A requirement for programmatically taking voice calls is a dedicated inbound number. Virtual telephone numbers live in the cloud, i.e., a data center. MessageBird offers numbers from different countries for a low monthly fee. Here's how to purchase one:

1. Go to the [Numbers](https://dashboard.messagebird.com/en/numbers) section of your MessageBird account and click Buy a number.
2. Choose the country in which you and your customers are located and make sure the _Voice_ capability is selected.
3. Choose one number from the selection and the duration for which you want to pay now. Buy a number screenshot
  ![Buy a number screenshot](https://developers.messagebird.com/assets/images/screenshots/automatedsurveys-node/buy-a-number.png)
4. Confirm by clicking **Buy Number**.

Excellent, you have set up your first virtual number!

### Connecting the Number to your Application

So you have a number now, but MessageBird has no idea what to do with it. That's why you need to define a _Flow_ next that ties your number to your webhook:

1. Open the Flow Builder and click **Create new flow**.
2. In the following dialog, choose **Create Custom Flow**.
  ![Create custom flow screenshot](https://developers.messagebird.com/assets/images/screenshots/automatedsurveys-node/create-a-new-flow.png)
3. Give your flow a name, such as "Survey Participation", select _Phone Call_ as the trigger and continue with **Next**. Create Flow, Step 1
  ![Create Flow, Step 1](https://developers.messagebird.com/assets/images/screenshots/automatedsurveys-node/setup-new-flow.png)
4. Configure the trigger step by ticking the box next to your number and click **Save**.
  ![Create Flow, Step 2](https://developers.messagebird.com/assets/images/screenshots/automatedsurveys-php/create-flow-2.png)

5. Press the small **+** to add a new step to your flow and choose **Fetch call flow from URL**.       
  ![Create Flow, Step 3](https://developers.messagebird.com/assets/images/screenshots/automatedsurveys-php/create-flow-3.png)

6. Paste the localtunnel base URL into the form and append `/callStep` to it - this is the name of our webhook handler route. Click **Save**.
  ![Create Flow, Step 4](https://developers.messagebird.com/assets/images/screenshots/automatedsurveys-php/create-flow-4.png)

7. Hit **Publish** and your flow becomes active!

## Implementing the Call Steps

The routes `get /callStep` and `post /callStep` in `app.rb` contains the implementation of the survey call flow.  It starts with the basic structure for a hash object called `flow`, which we'll extend depending on where we are within our survey:

``` ruby
%i[get post].each do |method|
  send method, '/callStep' do
    # Prepare a Call Flow that can be extended
    flow = {
      title: 'Survey Call Step',
      steps: []
    }
```

Next, we connect to MongoDB, select a collection and try to find an existing call:

``` ruby
collection = DB[:survey_participants]

call_id = params['callID']

doc = collection.find(callId: call_id).first
```

The application continues inside the callback function. First, we determine the ID (i.e., array index) of the next question, which is 0 for new participants or the number of existing answers plus one for existing ones:

``` ruby
# Determine the next question
question_id = doc.nil? ? 0 : doc['responses'].length + 1
```

For new participants, we also need to create a document in the MongoDB collection and persist it to the database. This record contains the identifier of the call and the caller ID, which are taken from the query parameters sent by MessageBird as part of the webhook (i.e., call flow fetch) request, `callID` and `destination` respectively. It includes an empty responses array as well.

``` ruby
if doc.nil?
  # Create new participant database entry
  doc = {
    callId: params['callID'],
    number: params['destination'],
    responses: []
  }
  collection.insert_one(doc)
end
```

The answers are persisted by adding them to the responses array and then updating the document in the MongoDB collection. For every answer we store two identifiers from the parsed JSON request body: the `legId` that identifies the caller in a multi-party voice call and is required to fetch the recording, as well as the id of the recording itself which we store as `recordingId`:

```ruby
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
```

Now it's time to ask a question. Let's first check if we reached the end of the survey. That is determined by whether the question index equals the length of the questions list and therefore is out of bounds of the array, which means there are no further questions. If so, we thank the caller for their participation:

``` ruby
if question_id == QUESTIONS.length
  # All questions have been answered
  flow[:steps].push(say('You have completed our survey. Thank you for participating!'))
```

You'll notice the `say()` function. It is a small helper function we've declared separately in the initial section of `app.rb` to simplify the creation of `say` steps as we need them multiple times in the application. The function returns the action in the format expected by MessageBird so it can be added to the steps of a flow using `push()`, as seen above.

A function like this allows setting options for `say` actions at a central location. You can modify it if you want to, for example, specify another language or voice:

``` ruby
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
```

Back in the route, there's an `else`-block that handles all questions other than the last. There's another nested `if`-statement in it, though, to treat the first question, as we need to read a welcome message to our participant before the question:

``` ruby
if question_id.zero?
  # Before first question, say welcome
  flow[:steps].push(say("Welcome to our survey! You will be asked #{QUESTIONS.length}questions. The answers will be recorded. Speak your response for each and press any key on your phone to move on to the next question. Here is the first question:"))
end
```

Finally, here comes the general logic used for each question:

* Ask the question using `say`.
* Request a recording.

``` ruby
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
```

The `record` step is configured so that it finishes when the caller presses any key on their phone's keypad (`finishOnKey` attribute) or when MessageBird detects 10 seconds of silence (`timeout` attribute). By specifying the URL with the onFinish attribute we can make sure that the recording data is sent back to our route and that we can send additional steps to the caller. Building the URL with protocol and hostname information from the request ensures that it works wherever the application is deployed and also behind the tunnel.

Only one tiny part remains: the last step in each webhook request is sending back a JSON response based on the `flow` object:

``` ruby
content_type :json
flow.to_json
```

## Building an Admin View

The survey application also contains an admin view that allows us to view the survey participants and listen to their responses. The implementation of the `get '/admin'` route is straightforward, it essentially loads everything from the database plus the questions data and adds it to the data available for an [ERB template](https://ruby-doc.org/stdlib-2.5.1/libdoc/erb/rdoc/ERB.html).

The template, which you can see in `views/participants.erb`, contains a basic HTML structure with a three-column table. Inside the table, two nested loops over the participants and their responses add a line for each answer with the number of the caller, the question and a "Listen" button that plays it back.

Let's have a more detailed look at the implementation of this "Listen" button. On the frontend, the button calls a Javascript function called `playAudio()` with the `callId`, `legId` and `recordingId` inserted through ERB expressions:

``` HTML
<button onclick="playAudio('<%= p[:callId] %>','<%= response[:legId] %>','<%= response[:recordingId] %>')">Listen</button>
```

The implementation of that function dynamically generates an invisible, auto-playing HTML5 audio element:

``` javascript
function playAudio(callId, legId, recordingId) {
    document.getElementById('audioplayer').innerHTML
        = '<audio autoplay="1"><source src="/play/' + callId
            + '/' + legId + '/' + recordingId
            + '" type="audio/wav"></audio>';
}
```

As you can see, the WAV audio is requested from a route of the survey application. This route acts as a proxy server that fetches the audio from MessageBird's API and uses the `pipe()` function to forward it to the frontend. This architecture is necessary because we need a MessageBird API key to fetch the audio but don't want to expose it on the client-side of our application. We use request to make the API call and add the API key as an HTTP header:

``` ruby
get '/play/:callId/:legId/:recordingId' do
  uri = URI.parse("https://voice.messagebird.com/calls/#{params[:callId]}/legs/#{params[:legId]}/recordings/#{params[:recordingId]}.wav")

  http = Net::HTTP.new(uri.host, uri.port)

  request = Net::HTTP::Post.new(uri.request_uri)
  request['Authorization'] = "AccessKey #{ENV['MESSAGEBIRD_API_KEY']}"

  # stream back the contents
  stream(:keep_open) do |out|
    http.request(request) do |f|
      f.read_body { |ch| out << ch }
    end
  end
end
```

As you can see, the API key is taken from an environment variable. To provide the key in the environment variable, [dotenv](https://rubygems.org/gems/dotenv) is used. We've prepared an env.example file in the repository, which you should rename to .env and add the required information. Here's an example:

```
MESSAGEBIRD_API_KEY=YOUR-API-KEY
```

You can create or retrieve a live API key from the [API access (REST) tab](https://dashboard.messagebird.com/en/developers/access) in the [Developers section](https://dashboard.messagebird.com/en/developers/settings) of your MessageBird account.

## Testing your Application

Check again that you have set up your number correctly with a flow to forward incoming phone calls to an ngrok URL and that the tunnel is still running. Remember, whenever you start a fresh tunnel, you'll get a new URL, so you have to update the flows accordingly.

To start the application, let's open another console window as your existing console window is already busy running your tunnel. On a Mac you can press Command + Tab to open a second tab that's already pointed to the correct directory. With other operating systems you may have to resort to open another console window manually. Either way, once you've got a command prompt, type the following to start the application:

```
ruby app.rb
```

Now, take your phone and dial your survey number. You should hear the welcome message and the first question. Speak an answer and press any key. At that moment you should see some database debug output in the console. Open http://localhost:4567/admin to see your call as well. Continue interacting with the survey. In the end, you can refresh your browser and listen to all the answers you recorded within your phone call.

Congratulations, you just deployed a survey system with MessageBird!

## Supporting Outbound Calls

The application was designed for incoming calls where survey participants call a virtual number and can provide their answers. The same code works without any changes for an outbound call scenario as well. The only thing you have to do is to start a call through the API or other means and use a call flow that contains a `fetchCallFlow` step pointing to your webhook route.

## Nice work!

You now have a running integration of MessageBird's Voice API!

You can now leverage the flow, code snippets and UI examples from this tutorial to build your own automated voice survey. Don't forget to download the code from the [MessageBird Developer Tutorials GitHub repository](https://github.com/messagebirdguides/automated-surveys-ruby).

## Next steps 🎉

Want to build something similar but not quite sure how to get started? Please feel free to let us know at support@messagebird.com, we'd love to help!
