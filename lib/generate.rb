#/usr/bin/env ruby

require 'nokogiri'
require 'securerandom'
require 'time'
require 'yaml'

# Some itunes bs
ITUNES_XMLNS = {
  'xmlns:content' => "http://purl.org/rss/1.0/modules/content/",
  'xmlns:wfw' => "http://wellformedweb.org/CommentAPI/",
  'xmlns:itunes' => "http://www.itunes.com/dtds/podcast-1.0.dtd",
  'xmlns:dc' => "http://purl.org/dc/elements/1.1/",
  'xmlns:media' => "http://www.rssboard.org/media-rss",
  'xmlns:googleplay' => "http://www.google.com/schemas/play-podcasts/1.0",
  'xmlns:atom' => "http://www.w3.org/2005/Atom",
  'version' => '2.0'
}


EN_US = 'en-US'

# Common attrs
GITHUBLINK = 'https://github.com/micahlagrange/ruby-podcast-rss-generator'

conf = YAML.load_file(ARGV[0])
S3_RSS_URL    = conf['s3']['rss_url'] # the full path to the podcast.xml hosted in s3
S3_IMAGES_URL = conf['s3']['images_url'] # The base directory in s3 where all images will live
S3_MP3S_URL   = conf['s3']['episodes_url'] # The base directory in s3 where all episodes will live

Channel = Struct.new(:author, :episodes, :description, :link, :title, :language, :explicit, :image_path)
Episode = Struct.new(:title, :media_path, :description, :pubdate, :image_path, :episode_type, :episode_number, :author, :keywords) do
  def pubdate_rfc822
    Time.parse(pubdate).utc.rfc2822
  end
  def publish_date_in_past?
    Time.now.utc > Time.parse(pubdate).utc
  end
  def to_xml(xml)
    xml.title title
    xml.description {xml.cdata description}
    xml.send('itunes:explicit', 'no')
    xml.pubDate pubdate_rfc822
    xml.enclosure(url: S3_MP3S_URL + media_path, type: 'audio/mpeg')
    xml.send('media:content', url: S3_MP3S_URL + media_path, type: 'audio/mpeg', isDefault: true, medium: 'audio') { xml.send('media:title', {type: 'plain'}, title) }
    xml.send('itunes:author', author)
    xml.guid({isPermaLink: false}, guid)
    xml.send('itunes:keywords', keywords)
    xml.send('itunes:image', {href: S3_IMAGES_URL + image_path})
    xml.send('itunes:episodeType', episode_type)
    xml.send('content:encoded') { xml.cdata description }
    xml.send('itunes:episode', episode_number)
  end
  
  def guid
    passwd = []
    3.times do
      passwd << SecureRandom.uuid.tr('-','')
    end
    passwd.join(':')
  end
end

def new_episode(title:,media_path:,description:,pubdate:,image_path:,episode_type:'full',number:,author:,keywords:)
  Episode.new(title,media_path,description,pubdate.to_s,image_path,episode_type,number,author,keywords)
end

def new_channel(conf)
  defaults = {'language' => EN_US, 'explicit' => 'no'}
  defaults.each do |k,v|
    defaults[k] = conf['channel'][k] if conf['channel'].key?(k)
  end
  Channel.new(
    conf['channel']['author'],
    conf['channel']['episodes'],
    conf['channel']['description'],
    conf['channel']['link'],
    conf['channel']['title'],
    defaults['language'],
    defaults['explicit'],
    conf['channel']['image_path'],
  )
end

def symbolize_keys(hash)
  new_hash = {}
  hash.each do |k,v|
    new_hash[k.to_sym] = v
  end
  new_hash
end


channel = new_channel(conf)
# Add dynamic attributes to episode that should most of the time be inherited from channel, but can be overridden for each episode in the channel's yaml
channel.episodes.each do |e|
  e['author'] = channel.author unless e.has_key?('author')
  e['image_path'] = channel.image_path
end
episodes = channel.episodes.map{|e| new_episode(symbolize_keys(e))}

feed_xml = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
  xml.rss(ITUNES_XMLNS) {
    xml.channel {
      xml.title channel.title
      xml.link channel.link
      xml.lastBuildDate episodes.select(&:publish_date_in_past?).last.pubdate_rfc822 unless episodes.select(&:publish_date_in_past?).empty?
      xml.description channel.description
      xml.send('itunes:author', channel.author)
      xml.send('itunes:subtitle', channel.description)
      xml.send('itunes:summary', channel.description)
      xml.generator GITHUBLINK
      xml.language channel.language
      xml.send('atom:link', {href: S3_RSS_URL, rel: 'self', type: 'application/rss+xml'})
      xml.send('itunes:explicit', channel.explicit)
      episodes.each do |ep|
        xml.item {
          ep.to_xml(xml)
        }
      end
    }
  }
end.to_xml

$stdout.write feed_xml