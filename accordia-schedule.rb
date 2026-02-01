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

require "./google-api.rb"


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
