#!/usr/bin/env ruby
# -*- coding:utf-8 -*-

#
# アコーディアのレッスン日を取得して、google カレンダに登録する
# 
require 'optparse'
require "date"
$stdout.sync = true

$O = { headless: true }

exit(1) unless ARGV.options {|opt|
  opt.on( '--[no-]headless' )
  opt.on( '-v', '--verbose' )
  opt.on( '-n', '--suppress' )
  opt.on( '--skip' )
  opt.parse!( into: $O )
}


p $O  if $O[:verbose]

require 'pp'

ENV["FERRUM_CLICK_WAIT"] = "0.0"
require 'ferrum'

def log( msg )
  puts msg
  yield
  puts "done"
end


def wait
  @page.network.wait_for_idle( timeout: 10 )
  @page.wait_for_reload
end



############################################

@top_page = 'https://www.accordiagolf.com/school/sp/login.html'
#https://www.accordiagolf.com/school/sp/login_exec.php?card_no=5970547&year=1961&month=03&day=17

def get_accordia_schedule

  begin
    @browser = Ferrum::Browser.new(
      headless: $O[:headless],
    )
    @page = @browser.create_page
    log( "go_to @top_page" ) {
      @page.go_to( @top_page );   sleep 0.5;
    }

    log( "enter login words, and submit" ) {
      { card_no: "5970547",
        year:    "1961",
        month:   "03",
        day:     "17" }.each do |k,v|
        input = @page.xpath( "//input[@name='#{k}']")[0]; sleep 0.2;
        input.focus.type( "#{v}" ); sleep 0.5
      end

      @page.xpath( "//input[@type='submit']")[0].click; wait
    }

    log( "read schedule..." ) {
      @page.xpath( "//a[contains(., 'スケジュール一覧')]")[0].click; wait

      # 一覧の中のカレンダーの年月
      yymm_s = @page.
                 xpath( "//section[@class='com_body com_calendar']")[0].
                 xpath( "h1" ).map do |sel|
        y, m = sel.text.match( /(\d+)年(\d+)月/ ).to_a[1,2]
        "#{y}/#{m}"
      end

      @active_yymmdd_s = 
        @page.xpath( "//table[@class='lesson_tra_caltable']").map.with_index do |sel, i|
        sel.xpath( ".//td[@class='active']" ).map do |sel|
          DateTime.parse( "#{yymm_s[i]}/#{sel.text.strip}" )
        end.tap do |days|
          puts "#{yymm_s[i]} #{days.size} active days"
        end
      end.flatten
    }    

    if $O[:verbose]
      puts "@active_yymmdd_s"
      p @active_yymmdd_s
    end

    #  @page.xpath( "//a[@class='open_lesson']").each do |sel|
    #    p [ sel.text, sel.attribute( "rel" ) ]
    #  end
    # 日にちをクリックしたときのダイアログを調べて
    # 予約日を抽出する
    @reserved_days =
      @page.xpath( "//section[@class='modal modal_lessondetail']").map do |sel|
      if $O[:verbose]
        # m20260107
        p [ sel.attribute( "id" ), sel.text.gsub( /\s+/, " " ) ]
      end
      _, yy, mm, dd = sel.attribute( "id" ).match( /m(\d{4})(\d{2})(\d{2})/m ).to_a
      _, hh, min    = sel.text.match( /(\d+):(\d+)～/m ).to_a
      DateTime.parse( "%s/%s/%s %s:%s +09:00" % [ yy, mm, dd, hh, min ] ) #.rfc3339
      #.tap{ |d| p [ yy, mm, dd, hh, min ], d }
    end.tap do |days|
      puts "#{days.size} days are reserved"
      days.
        group_by{ |dt| "%4d/%02d" % [ dt.year, dt.mon ] }.each do |ym, days|
        puts "  #{ym}: #{days.map{|dt| dt.strftime( "%d(%a)" )}.join(', ')}"
      end
    end.map do |dt|
      dt.strftime( "%Y/%m/%d %H:%M" )
    end

    if $O[:verbose]
      puts "@reserved_days"
      p @reserved_days
    end
    
  rescue
    $stderr.puts $!
    $stderr.puts $!.backtrace
    gets    unless  $O[:headless]

  ensure
    @browser.quit  if @browser

  end

end # get_accodia_schedule


get_accordia_schedule()  unless $O[:skip]


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

######################################

# OutLook と Google を比較して Google Calendar を更新

# src にあって dst にない event
def missing_ev( src_events, dst_events, diff_msg = nil )
  def trim( a )
    ("\r\n"+a+"\r\n").gsub( /[ \t　]+/, " " ).gsub( /([ ]+)?[\r\n]+([ ]+)?/, "\n" )
  end
  def eq_desc( a, b )
    trim( a.description ) == trim( b.description )
  end

  src_events.select{ |src_ev|
    dst_events.all?{ |dst_ev|
      ! ( src_ev.text == dst_ev.text &&
        ( eq_desc( src_ev, dst_ev ) ).tap{ |t|
        #p [ src_ev.description, dst_ev.description ]  if !t && $O[:debug]
            if !t && diff_msg
              tmpf = [src_ev, dst_ev].map do |ev|
                desc = trim( ev.description )
                tp = Tempfile.open( "sync-google" )
                tp.puts desc
                tp.close
                tp
              end
              diff_msg[ src_ev.text ] =
                %x[ diff "#{tmpf[0].path}" "#{tmpf[1].path}" ].
                  split(/\n/).
                  map { |s| "\t#{s}" }.
                  join( "\n" )
            end
        }
      )
    }
  }
end

# アコーディアのスケジュールで予約可能な日にちの範囲
date_from = @active_yymmdd_s.min
date_to   = @active_yymmdd_s.max + 1

begin
  log( 'getting events from google ... ' ) {
    @google_api = GoogleApi.new

    raise ""  unless  @google_api.gcal
    @ggl_events =  @google_api.get_events( date_from, date_to )
  }

  @ggl_days = {}
  @ggl_events.select do |ev|
    ev.summary == "アコーディア"
  end.each do |ev|
    dt = ev.start.date_time.strftime( "%Y/%m/%d %H:%M" )
    @ggl_days[ dt ] = ev
    p [ dt, ev.summary ]
  end

  

  puts "to add"
  (@reserved_days - @ggl_days.keys).each do |dt|
    puts "adding  #{dt}"
    start = DateTime.parse( "#{dt} +09:00" )
    @google_api.add_event( start, start + 1r/24,
                           'アコーディア' )   unless $O[:suppress]
  end
  puts "to delete"
  (@ggl_days.keys - @reserved_days).each do |dt|
    puts "deleting  #{dt}"
    @google_api.delete_events( @ggl_days[ dt ] )  unless $O[:suppress]
  end

  
rescue
  puts $!.message
  $stderr.puts $!.backtrace
  exit 2
  if $!.message =~ /expired/i
    url = 'https://console.cloud.google.com/apis/credentials?hl=ja&inv=1&invt=Abp2pA&project=syncol'
    url = 'https://console.cloud.google.com/auth/clients/create?previousPage=%2Fapis%2Fcredentials%3Fhl%3Dja%26invt%3DAbuGGA%26project%3Dsyncol&hl=ja&invt=AbuGGA&project=syncol'
    cmd = 'cygstart'
    cmd = GoogleApi::Browser
    puts %x[ '#{cmd}' '#{url}' ]

  end
  exit 2
end



__END__

=begin

選択可能な日  <td class が "active"
*    年月
**   予約していない日付
***  予約済： <a class が "open_lesson"

<section class="com_body com_calendar">
   <h1>2025年12月</h1>                       *
   <table ... class="lesson_tra_caltable"> 
   <h1>2026年01月</h1>
   <table ... class="lesson_tra_caltable"> 
     <tr>
       <td></td>
       <td></td>
       <td class="active"> 1 </td>           **
       <td class="active">
          <a href=..  class="open_lesson"    ***
       </td>
=end
