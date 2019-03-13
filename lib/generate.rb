#/usr/bin/env ruby

require 'nokogiri'
require 'securerandom'
require 'time'
require 'yaml'
require 'time'
require_relative './s3'

module Podcast
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

  DEFAULTS = {
    'language' => EN_US,
    'explicit' => 'no',
    'type' => 'episodic'
  }


  # Common attrs
  GITHUBLINK = 'https://github.com/micahlagrange/ruby-podcast-rss-generator'

  # Conf methods
  def self.declaration=(new_declaration)
    @declaration = OpenStruct.new(new_declaration)
  end
  def self.declaration
    @declaration
  end

  def self.defaults=(new_defaults)
    @channel_defaults = new_defaults
  end
  def self.defaults
    @channel_defaults || DEFAULTS
  end

  Channel = Struct.new(:author, :episodes, :long_description, :short_description, :link, :title, :language, :explicit, :type, :image_path, :keywords, :owner_email, :owner_name) do
    def to_xml
      Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.rss(ITUNES_XMLNS) {
          xml.channel {
            xml.title title
            xml.generator GITHUBLINK
            xml.lastBuildDate episodes.last.pubdate_rfc822 if episodes.all?(&:publish_date_in_past?) unless episodes.empty?
            xml.link link
            xml.language language
            xml.description long_description
            xml.send('atom:link', {href: Podcast.declaration.s3['rss_url'], rel: 'self', type: 'application/rss+xml'})
            if owner_email && owner_name
              xml.send('itunes:owner') {
                xml.send('itunes:name', owner_name)
                xml.send('itunes:email', owner_email)
              }
            end  
            xml.send('itunes:subtitle', short_description)
            xml.send('itunes:summary', long_description)
            xml.send('itunes:type', type)  
            xml.send('itunes:explicit', explicit)
            xml.send('itunes:keywords', keywords) if keywords
            xml.send('itunes:image', {href: Podcast.declaration.s3['images_url'] + image_path})
            xml.send('itunes:author', author)
            episodes.each do |ep|
              xml.item { ep.to_xml(xml) } if ep.publish_date_in_past?
            end
          }
        }
      end
    end
  end

  Episode = Struct.new(:title, :media_path, :description, :pubdate, :image_path, :episode_type, :episode_number, :author, :keywords, :guid, :category, :sub_category) do
    def pubdate_rfc822
      pubdate.rfc2822
    end
    def publish_date_in_past?
      Time.now > pubdate
    end
    def to_xml(channel_xml)
      channel_xml.pubDate pubdate_rfc822
      if category
        channel_xml.send('itunes:category', {text: category}) {
          channel_xml.send('itunes:category', {text: sub_category}) if sub_category
        }
      end
      channel_xml.title title
      channel_xml.description {channel_xml.cdata description}
      channel_xml.guid({isPermaLink: false}, guid)
      channel_xml.enclosure(url: Podcast.declaration.s3['episodes_url'] + media_path, type: 'audio/mpeg')
      # itunes
      channel_xml.send('itunes:image', {href: Podcast.declaration.s3['images_url'] + image_path})
      channel_xml.send('content:encoded') { channel_xml.cdata description }
      channel_xml.send('media:content', url: Podcast.declaration.s3['episodes_url'] + media_path, type: 'audio/mpeg', isDefault: true, medium: 'audio') { channel_xml.send('media:title', {type: 'plain'}, title) }
      channel_xml.send('itunes:keywords', keywords)
      channel_xml.send('itunes:episodeType', episode_type)
      channel_xml.send('itunes:episode', episode_number)
      channel_xml.send('itunes:explicit', 'no')
      channel_xml.send('itunes:author', author)
    end
  end

  def self.new_episode(title:,media_path:,description:,pubdate:,image_path:,episode_type:'full',number:,author:,keywords:,category:,sub_category:,bucket:)

    pubdate = Time.parse(pubdate).utc
    $stderr.write "looking in s3 for episode #{number}:'#{title}' at path episodes/#{media_path}\n"
    s3episode = Podcast::S3Buckets.episodes(bucket: bucket).find{|e| e.path == "episodes/#{media_path}"}
    
    if s3episode
      if s3episode.guid.nil?
        $stderr.write("Guid is nil for episode #{number}. guid must be present for the xml in the rss feed.")
        abort
      end
      $stderr.write "Found episode #{s3episode}\n"
      guid = s3episode.guid
    end
    Episode.new(title,media_path,description,pubdate,image_path,episode_type,number,author,keywords,guid,category,sub_category)
  end

  def self.new_channel(declaration)
    defaults.each do |k,v|
      defaults[k] = declaration.channel[k] if declaration.channel.key?(k)
    end
    Channel.new(
      declaration.channel['author'],
      declaration.channel['episodes'],
      declaration.channel['long_description'],
      declaration.channel['short_description'],
      declaration.channel['link'],
      declaration.channel['title'],
      defaults['language'],
      defaults['explicit'],
      defaults['type'],
      declaration.channel['image_path'],
      declaration.channel['keywords'],
      declaration.channel['owner_email'],
      declaration.channel['owner_name']
    )
  end

  def self.symbolize_keys(hash)
    new_hash = {}
    hash.each do |k,v|
      new_hash[k.to_sym] = v
    end
    new_hash
  end

  def self.converge(conf)
    Podcast.declaration = conf

    channel = new_channel(declaration)
    # Add dynamic attributes to episode that should most of the time be inherited from channel, but can be overridden for each episode in the channel's yaml
    channel.episodes.each do |e|
      e['author'] = channel.author unless e.has_key?('author')
      e['image_path'] = channel.image_path
      e['category'] = nil unless e.key?('category')
      e['sub_category'] = nil unless e.key?('sub_category')
      e['bucket'] = Podcast.declaration.s3['bucket']
    end

    # Create new episodes from channel episodes yaml
    channel.episodes = channel
      .episodes
      .map { |e| new_episode(symbolize_keys(e)) }
      .select(&:publish_date_in_past?)

    channel.to_xml
  end
end