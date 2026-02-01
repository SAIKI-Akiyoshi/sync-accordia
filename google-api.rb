#
# Google Calendar へのイベント add/delete
#
# トークンの期限切れでAPI使用の認証が必要な場合、
# 認証・認可のプロセスでフロントエンドとしてブラウザを起動する。
#
# google へのログインを自動化するために Ferrum を使った
# chrome-fake.rb で Chrome を起動してそれを操作する。
#

require "google/apis/calendar_v3"
require "googleauth"
require "googleauth/stores/file_token_store"
require "fileutils"


FILEDIR            = File.dirname(__FILE__)
$:.unshift FILEDIR # ロードパスにカレントディレクトリを追加

class GoogleEvent
  attr :event

  def initialize( ev )
    @start_at    = Time.parse( ev.start.date_time.rfc3339 )
    @end_at      = Time.parse( ev.end.date_time.rfc3339 )
    @title       = ev.summary.to_s
    @description = ev.description.to_s

    @event = ev
  end

end

class GoogleApi
  attr_reader :gcal

  REDIRECT_URI     = "http://localhost:8000"
  APPLICATION_NAME = "Google Calendar API Ruby Quickstart".freeze
  CREDENTIALS_PATH = "#{FILEDIR}/credentials.json".freeze
  # The file token.yaml stores the user's access and refresh tokens, and is
  # created automatically when the authorization flow completes for the first
  # time.
  TOKEN_PATH       = "#{FILEDIR}/token.yaml".freeze
  SCOPE = Google::Apis::CalendarV3::AUTH_CALENDAR_EVENTS #AUTH_CALENDAR_READONLY

  GAuth = Google::Auth
  GCal  = Google::Apis::CalendarV3

  Browser = 'ruby chrome-fake.rb'

  def loopback_ip_flow url
    puts 'start: Loopback Interface Redirection'

    # Process: HTTP Server
    reader, writer = IO.pipe      # パイプを作成

    puts 'start HTTP Server'
    servlet_pid = fork do
      require 'webrick'
      code = ''
      server = WEBrick::HTTPServer.new(
        Port: 8000,
        Logger: WEBrick::Log.new( '/dev/null' ),
        AccessLog: []
      )
      server.mount_proc('/oauth2callback') do |req, res|
        query_params = URI.decode_www_form(req.query_string)    # Array
        code = query_params.to_h[ 'code' ].to_s

        res.body = %Q(
          <html>
            code=#{code}
            <br>
            <br>
            <center><font size=+1> Quit Browser </font></center>
          </html>
          )

        writer.puts code
      end

      trap( :SIGINT ) {  # Ctrl+C
        server.shutdown
      }

      begin
        server.start
      ensure
        writer.puts ''
        writer.close
      end

    end # fork

    puts 'start Browser'
    # Process: Browser
    cmd = "#{Browser} '#{url}'"
    p cmd
    browser_pid = spawn( cmd )

    code = nil

    #
    # watch BROWSER
    #
    browser_thr = Thread.new do
      Process.wait( browser_pid );  browser_pid = nil
      puts 'browser: TERMINATED'

      if servlet_pid
        puts 'TERMINATING servlet...'
        Process.kill( 'SIGINT', servlet_pid )
      end
    end

    # getting the code
    trap( "SIGINT", nil )
    code = reader.gets.chomp       # from HTTP Server
    trap( "SIGINT", "DEFAULT" )
    reader.close
    puts "code: '#{code}'"

    Process.kill( 'SIGINT', servlet_pid )
    Process.wait( servlet_pid );  servlet_pid = nil
    puts "srvlet: TERMINATED"

    if browser_pid
      # system( "ps" )
      puts "TERMINATING browser...#{browser_pid}"
      Process.kill( 'SIGQUIT', browser_pid ) 
    end

    browser_thr.join
    # exit 3  if code == ''
    code
  end
  ##
  # Ensure valid credentials, either by restoring from the saved credentials
  # files or intitiating an OAuth2 authorization. If authorization is required,
  # the user's default browser will be launched to approve the request.
  #
  # @return [Google::Auth::UserRefreshCredentials] OAuth2 credentials
  def authorize
    client_id   = GAuth::ClientId.from_file CREDENTIALS_PATH
    token_store = GAuth::Stores::FileTokenStore.new file: TOKEN_PATH
    authorizer  = GAuth::UserAuthorizer.new client_id, SCOPE, token_store
    user_id     = "default"
    credentials = authorizer.get_credentials user_id
    if credentials.nil?
      url  = authorizer.get_authorization_url base_url: REDIRECT_URI
      code = loopback_ip_flow( url )
      unless  code == ''
        credentials = authorizer.get_and_store_credentials_from_code(
          user_id: user_id, code: code, base_url: REDIRECT_URI
        )
      end
    end
    credentials
  end

  def initialize
    # Initialize the API
    @gcal = GCal::CalendarService.new
    @gcal.client_options.application_name = APPLICATION_NAME
    @gcal.authorization = authorize

    @calendar_id = "primary"
  end

  def add_event( start_at, end_at, title )
    dtime = ->( time ) {
      GCal::EventDateTime.new( date_time: time.rfc3339 )
    }
    @gcal.insert_event(
      @calendar_id,
      GCal::Event.new( start:   dtime.(start_at),
                       end:     dtime.(end_at),
                       summary: title )
    )
  end

  def delete_events( events )
    [events].flatten.each{ |ev|
      @gcal.delete_event( @calendar_id, ev.id )
    }
  end

  def get_events( start_at, end_at )
    events = @gcal.list_events( @calendar_id,
                                max_results:   500,
                                single_events: true,
                                order_by:      "startTime",
                                time_min:      start_at.rfc3339,
                                time_max:      end_at.rfc3339,
                              ).items
    puts "#{events.size} events from google"
    return events

    events.map do |ev|
      begin
        GoogleEvent.new( ev ).tap do |ev|
          puts ev.text  if $O[:verbose]
        end.then do |ev|
          if ev.start_at < start_at
            puts "  ignore #{ev.text}"
            puts "  #{ev.start_at.strftime('%Y/%m/%d')} < #{start_at.strftime('%Y/%m/%d')}"
            nil
          else
            ev
          end
        end
      rescue
        puts "!  #{$!}"
        puts "!  skip '#{ev.summary.to_s}'"
        p ev
        $stderr.puts $!.backtrace
        nil
      end
    end.select do |ev|
      ev != nil
    end
  end

end
