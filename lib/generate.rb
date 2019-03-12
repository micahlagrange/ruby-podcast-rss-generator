#/usr/bin/env ruby

require 'nokogiri'
require 'securerandom'
require 'time'
require 'yaml'
require 'time'
require_relative './s3'

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
# Conf
conf = YAML.load_file(ARGV[0])
S3_RSS_URL    = conf['s3']['rss_url'] # the full path to the podcast.xml hosted in s3
S3_IMAGES_URL = conf['s3']['images_url'] # The base directory in s3 where all images will live
S3_MP3S_URL   = conf['s3']['episodes_url'] # The base directory in s3 where all episodes will live

Channel = Struct.new(:author, :episodes, :long_description, :short_description, :link, :title, :language, :explicit, :type, :image_path, :keywords, :owner_email, :owner_name)
Episode = Struct.new(:title, :media_path, :description, :pubdate, :image_path, :episode_type, :episode_number, :author, :keywords, :guid, :category, :sub_category) do
  def pubdate_rfc822
    pubdate.rfc2822
  end
  def publish_date_in_past?
    Time.now > pubdate
  end
  def to_xml(xml)
    xml.pubDate pubdate_rfc822
    if category
      xml.send('itunes:category', {text: category}) {
        xml.send('itunes:category', {text: sub_category}) if sub_category
      }
    end
    xml.title title
    xml.description {xml.cdata description}
    xml.send('itunes:image', {href: S3_IMAGES_URL + image_path})
    xml.send('content:encoded') { xml.cdata description }
    xml.enclosure(url: S3_MP3S_URL + media_path, type: 'audio/mpeg')
    xml.send('media:content', url: S3_MP3S_URL + media_path, type: 'audio/mpeg', isDefault: true, medium: 'audio') { xml.send('media:title', {type: 'plain'}, title) }
    xml.guid({isPermaLink: false}, guid)
    xml.send('itunes:keywords', keywords)
    xml.send('itunes:episodeType', episode_type)
    xml.send('itunes:episode', episode_number)
    xml.send('itunes:explicit', 'no')
    xml.send('itunes:author', author)
  end

end

def new_episode(title:,media_path:,description:,pubdate:,image_path:,episode_type:'full',number:,author:,keywords:,category:,sub_category:,bucket:)

  pubdate = Time.parse(pubdate).utc
  $stderr.write "looking in s3 for episode #{number}:'#{title}' at path episodes/#{media_path}\n"
  s3episode = Podcast::S3Buckets.episodes(bucket: bucket).find{|e| e.path == "episodes/#{media_path}"}
  
  if s3episode
    if number != s3episode.episode_number ||  pubdate != s3episode.pubdate
      $stderr.write "[WARNING]:: Found episode #{number}: '#{title}' in s3 but the metadata does not match. One of the following may be the issue:\n"
      $stderr.write "#{number} == #{s3episode.episode_number.to_i} #{number == s3episode.episode_number.to_i}.\n"
      $stderr.write "#{pubdate} == #{s3episode.pubdate} #{pubdate == s3episode.pubdate}\n"
      $stderr.write "It is possible that the defined properties just need to pushed out to s3 again, or that someone modified the s3 object manually.\n"
    end
    if s3episode.guid.nil?
      $stderr.write("Guid is nil for episode #{number}. guid must be present for the xml in the rss feed.")
      abort
    end
    $stderr.write "Found episode #{s3episode}\n"
    guid = s3episode.guid
    pubdate = s3episode.pubdate
  end
  Episode.new(title,media_path,description,pubdate,image_path,episode_type,number,author,keywords,guid,category,sub_category)
end

def new_channel(conf)
  defaults = {'language' => EN_US, 'explicit' => 'no', 'type' => 'episodic'}
  defaults.each do |k,v|
    defaults[k] = conf['channel'][k] if conf['channel'].key?(k)
  end
  Channel.new(
    conf['channel']['author'],
    conf['channel']['episodes'],
    conf['channel']['long_description'],
    conf['channel']['short_description'],
    conf['channel']['link'],
    conf['channel']['title'],
    defaults['language'],
    defaults['explicit'],
    defaults['type'],
    conf['channel']['image_path'],
    conf['channel']['keywords'],
    conf['channel']['owner_email'],
    conf['channel']['owner_name']
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
  e['category'] = nil unless e.key?('category')
  e['sub_category'] = nil unless e.key?('sub_category')
  e['bucket'] = conf['s3']['bucket']
end

# Create new episodes from channel episodes yaml
episodes = channel.episodes.map{|e| new_episode(symbolize_keys(e))}

feed_xml = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
  xml.rss(ITUNES_XMLNS) {
    xml.channel {
      xml.title channel.title
      xml.generator GITHUBLINK
      xml.send('itunes:type', channel.type)
      xml.lastBuildDate episodes.select(&:publish_date_in_past?).last.pubdate_rfc822 unless episodes.select(&:publish_date_in_past?).empty?
      xml.link channel.link

      if channel.owner_email && channel.owner_name
        xml.send('itunes:owner') {
          xml.send('itunes:name', channel.owner_name)
          xml.send('itunes:email', channel.owner_email)
        }
      end

      xml.description channel.long_description
      xml.send('itunes:subtitle', channel.short_description)
      xml.send('itunes:summary', channel.long_description)

      xml.send('itunes:explicit', channel.explicit)
      xml.send('itunes:keywords', channel.keywords) if channel.keywords
      xml.send('itunes:image', {href: S3_IMAGES_URL + channel.image_path})
      xml.send('itunes:author', channel.author)
      xml.send('atom:link', {href: S3_RSS_URL, rel: 'self', type: 'application/rss+xml'})
      xml.language channel.language

      episodes.each do |ep|
        if ep.publish_date_in_past?
          xml.item {
            ep.to_xml(xml)
          }
        end
      end
    }
  }
end.to_xml

File.write('podcast.xml', feed_xml)
