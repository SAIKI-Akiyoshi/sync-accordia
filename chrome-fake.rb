#!/usr/bin/env ruby
# -*- coding:utf-8 -*-

#ferrum を使って Chrome を起動する

require 'optparse'
$stdout.sync = true

$O = { headless: false }

exit(1) unless ARGV.options {|opt|
  opt.on( '--[no-]headless' )
  opt.on( '-v', '--verbose' )
  opt.on( '-n', '--suppress' )
  opt.on( '--skip' )
  opt.parse!( into: $O )
}

require 'logger'

Log = Logger.new(
  STDOUT,
  formatter: proc do |severity, datetime, progname, msg|
    @start_time ||= Time.now.to_f
    sec = (datetime.to_f - @start_time).round(2)
    # [10.00 INFO] メッセージ
    "[#{"%8.3f" % sec} #{severity}] #{msg}\n"
  end
)

ENV["FERRUM_CLICK_WAIT"] = "0.0"
require 'ferrum'
@top_page = ARGV[0]


@browser = Ferrum::Browser.new(
  headless: false,
  window_size: [1200, 800],
  browser_options: {
    'no-first-run' => nil,
    'no-default-browser-check' => nil
  }
)

@page = @browser.create_page
Log.info "got_to #{ARGV[0]}"
@page.go_to( ARGV[0] ) 

trap( :SIGQUIT ) do
  puts "got :SIGQUIT"
  raise Interrupt
end

def wait 
  @page.network.wait_for_idle( timeout: 10 )
  @page.wait_for_reload
end

# Chrome が生きている限り待つ
sleep 1

input = ->(type,text) do
  Log.info "input #{type} ..."
  elm = @page.xpath( "//input[@type='#{type}']" )[0]; sleep 0.2
  elm.focus.type( "#{text}" ); sleep 0.5
end

last_text = ""
click = ->( text ) do
  Log.info "#{text}"
  cont = nil
  loop do
    last_text = @page.evaluate('document.body.innerText')
    cont  = @page.xpath( "//button[contains(., '#{text}')]" )[0]
    break if cont
    sleep 0.5
  end
  cont.click
end

input.( "email", "light299792@gmail.com" )
click.( "次へ" ); sleep 3

input.( "password", "Saiki0312" )
click.( "次へ" ); sleep 3

click.( "続行" )
last_text.split( /\n/ ).each { |s| puts "\t#{s}" }
sleep 3

click.( "続行" )
last_text.split( /\n/ ).each { |s| puts "\t#{s}" }


loop do
  begin
    
    sleep 1
    printf '.'; $stdout.flush
    pages = @browser.pages
    if pages.empty?
      puts "Chrome が閉じられました。終了します。"
      break
    end
  rescue Interrupt
    break
  rescue 
    puts $!
    break
  end
end
puts "quiting..."

@browser.quit rescue nil

