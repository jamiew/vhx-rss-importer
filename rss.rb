require 'rubygems'
require 'bundler/setup'
require 'mechanize'
require 'yaml'
require 'htmlentities'
require 'digest/md5'

def dirname
  File.expand_path(File.dirname($0))
end

def load_config
  config = YAML.load(File.open("#{dirname}/config.yml").read)
  raise "config.yml is blank" if config.nil?
  raise "config.yml is incomplete; config => #{config.inspect}" unless config['server'] && config['blogs']
  config
end

class RssScraper
  def initialize(config)
    unless config['url'] && config['username'] && config['api_token']
      raise "blog config is incomplete: url, username, api_token are required. config => #{config.inspect}"
    end

    @config = config
    @login = @config['username']
    @api_token = @config['api_token']
    @blog_url = (@config['url'] =~ /^http\:\/\// ? @config['url'] : "http://#{@config['url']}")
  end

  def log(msg)
    puts msg
  end

  def log_video(video)
    msg = "\nSharing #{video[:url]}"
    msg += " shared_at=#{video[:shared_at].inspect}" if video[:shared_at]
    msg += " share_comment=#{video[:share_comment].inspect}" if video[:share_comment]
    msg += " found_on_url=#{video[:found_on_url].inspect}"
    log(msg)
  end

  def agent
    # @agent ||= build_agent
    build_agent # fresh each time
  end

  def build_agent
    agent = Mechanize.new
    agent.user_agent = 'VHX Video Satellite <http://github.com/vhx> dev@vhx.tv'
    agent
  end

  def fetch_page(url, params={})
    agent.get(url, params)
  rescue Mechanize::ResponseCodeError
    STDERR.puts "Error fetching page #{url.inspect} => #{$!.inspect}"
    # TODO retry once or twice
    sleep 1
  end

  # FIXME really don't this here "storage mechanism"
  def last_seen_filename
    # "last_seen_url_#{@config['url'].gsub('.','-').gsub('/','-')}"
    "last_seen_url_#{Digest::MD5.hexdigest(@blog_url)}"
  end

  def last_seen_time
    File.mtime(last_seen_filename)
  rescue Errno::ENOENT # File doesn't exist
    nil
  end

  def last_seen_url
    return @last_seen_url if @last_seen_url
    last_seen_file = File.open("#{dirname}/#{last_seen_filename}") rescue nil
    @last_seen_url = last_seen_file && last_seen_file.read.strip.chomp || nil
    @last_seen_url = nil if @last_seen_url.empty?
    @last_seen_url
  end

  # For some reason this isn't being called as last_seen_url= ...
  # Aliased as set_last_seen_url() for now :-(
  # FIXME dirname hack being used since __FILE__ is where utils.rb is. Blech. :-((
  def last_seen_url=(url)
    filename = "#{dirname}/#{last_seen_filename}"
    puts "Writing last_seen_url... #{url.inspect}  filename=#{filename}"
    File.open("#{filename}", "w+") do |f|
      f.write(url)
    end
  end
  alias :set_last_seen_url :last_seen_url=

  def share_videos(videos)
    videos.each do |video|
      share_video(video)
      sleep 1
    end
  end

  def share_video(video)
    log_video(video)
    url = "http://#{$global_config['server']}/videos/share.xml?app_id=vhx_channels&login=#{@login}&api_token=#{@api_token}"
    if @config['dry_run'].to_s == 'true'
      log "DRY RUN, not posting..."
    else
      agent.post(url, video)
    end
    set_last_seen_url(video[:found_on_url])
  rescue Mechanize::ResponseCodeError
    STDOUT.print "\n"
    STDERR.puts "*** Error sharing video: #{$!.inspect} response=#{$!.page.body}"

    if agent.page.code.to_i == 401
      log "Bad auth credentials, halting"
      exit 1
    end
  end

  def identify_embeds(html)
    url = nil
    if html =~ /youtube\.com/
      matches = /youtube\.com\/v\/([^&#\?]+)/.match(html)
      matches ||= /youtube\.com\/\/watch\?v=([^&#\?"\\]+)/.match(html)
      matches ||= /youtube\.com\/\/embed\/([^&#\?\"]+)/.match(html) # iframe
      url = matches && "http://www.youtube.com/watch?v=#{matches[1]}"
    elsif html =~ /vimeo\.com/
      matches ||= /player\.vimeo\.com\/video\/(\d+)/.match(html)
      matches ||= /vimeo\.com\/(\d+)/.match(html)
      url = matches && "http://vimeo.com/#{matches[1]}"
    end
    return url
  end

  def fetch_posts(url)
    begin
      puts "fetch_posts() #{url.inspect} ..."
      page = agent.get(url)
      return page.body
    rescue Mechanize::ResponseCodeError, Timeout::Error
      STDERR.puts "Error fetching page #{url.inspect}: #{$!.inspect}"
      # TODO retry once or twice
      sleep 1
      return nil
    end
  end

  def videos_from_rss(data)
    doc = Nokogiri::XML.parse(data)
    log "videos_from_rss(): last_seen_url=#{last_seen_url.inspect}"
    videos = []
    (doc/'item').each {|item|
      video = videos_from_rss_item(item)
      if video.nil?
        # log "No video found for #{(item/'link')[0].content}"
      elsif video[:found_on_url] == last_seen_url
        log "this is the last_seen_url, stopping here."
        break
      else
        log "#{video[:found_on_url].inspect}: found video, #{video[:url].inspect} shared_at=#{video[:shared_at].inspect}"
        videos << video
      end
    }
    videos.flatten.compact
  end

  def videos_from_rss_item(item)
    content = (item/'content|encoded')[0].content
    # TODO strip cdata and parse content again; then grab object/embed/iframe tags
    # TODO need to HTML decode this comment before posting..?
    video_url = identify_embeds(content)
    return nil if video_url.nil? || video_url.empty?
    comment = @config['descriptions'].to_s == 'false' ? nil : (item/'description')[0].content

    original_url = (item/'link')[0].content
    found_on_url = expand_url(original_url).to_s.strip.chomp
    pub_date = (item/'pubDate')[0].content
    shared_at = Time.parse(pub_date)

    output = {:url => video_url, :original_url => original_url, :found_on_url => found_on_url, :share_comment => comment, :shared_at => shared_at}
    return output
  end

  def expand_url(url)
    begin
      uri = agent.head(url).uri
    rescue Net::HTTPInternalServerError
      STDERR.puts "500 Internal Server Error. url => #{url.inspect}"
      uri = nil
    end

    parsed = uri.to_s.gsub(uri.query.to_s,'').gsub(/\?$/,'') # FIXME /\?#{uri.query}/ regex not working which is actually safe
    parsed
  end

  def update
    data = fetch_posts(@blog_url)
    if data.nil? || data.empty?
      STDERR.puts "No data in response! @config=#{@config.inspect}"
      return nil
    end

    # Fetch and sort videos
    # FIXME do we even need to resort...?
    videos = videos_from_rss(data)
    videos = videos.sort_by{|v| v[:shared_at] }

    if videos.length <= 0
      puts "Nothing to post! We're done here."
      exit 0
    end

    # Auth to VHX and share
    # Work backwards so most recent post is posted last, so it's on top
    share_videos(videos)
  end
end




# ******************************************

$global_config = load_config
$global_config['blogs'].each do |opts|
  puts opts.inspect
  blog = RssScraper.new(opts)
  blog.set_last_seen_url(nil) if ENV['CLOBBER'].to_s == '1' || ENV['FORCE'].to_s == '1'
  blog.update
end
puts "\nDone"
