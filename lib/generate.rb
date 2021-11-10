# /usr/bin/env ruby

require "nokogiri"
require "securerandom"
require "time"
require "yaml"
require_relative "./s3"

module Podcast
  def self.mimetypes
    { ".wav" => "audio/wav", ".mp3" => "audio/mpeg", ".wave" => "audio/wav" }
  end

  # Some itunes bs
  ITUNES_XMLNS = {
    "xmlns:content" => "http://purl.org/rss/1.0/modules/content/",
    "xmlns:wfw" => "http://wellformedweb.org/CommentAPI/",
    "xmlns:itunes" => "http://www.itunes.com/dtds/podcast-1.0.dtd",
    "xmlns:dc" => "http://purl.org/dc/elements/1.1/",
    "xmlns:media" => "http://www.rssboard.org/media-rss",
    "xmlns:googleplay" => "http://www.google.com/schemas/play-podcasts/1.0",
    "xmlns:atom" => "http://www.w3.org/2005/Atom",
    "version" => "2.0",
  }

  # Common attrs
  GITHUBLINK = "https://github.com/micahlagrange/ruby-podcast-rss-generator"

  # Conf methods
  def self.declaration=(new_declaration)
    @declaration = OpenStruct.new(new_declaration)
  end

  def self.declaration
    @declaration
  end

  Channel = Struct.new(:author, :episodes, :long_description, :short_description, :link, :title, :explicit, :language,
                       :type, :image_path, :keywords, :owner_email, :owner_name, :category, :sub_category) do
    def to_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.rss(ITUNES_XMLNS) do
          xml.channel do
            xml.title title
            xml.generator GITHUBLINK
            xml.lastBuildDate episodes.last.pubdate_rfc822 if !episodes.empty? && episodes.all?(&:publish_date_in_past?)
            xml.link link
            xml.language language
            xml.description long_description
            xml.send("atom:link", { href: Podcast.declaration.s3["rss_url"], rel: "self", type: "application/rss+xml" })
            if owner_email && owner_name
              xml.send("itunes:owner") do
                xml.send("itunes:name", owner_name)
                xml.send("itunes:email", owner_email)
              end
            end
            xml.send("itunes:subtitle", short_description)
            xml.send("itunes:summary", long_description)
            xml.send("itunes:type", type)
            xml.send("itunes:explicit", explicit)
            xml.send("itunes:keywords", keywords) if keywords
            xml.send("itunes:image", { href: Podcast.declaration.s3["images_url"] + image_path })
            xml.send("itunes:author", author)
            xml.send("itunes:category", { text: category }) do
              xml.send("itunes:category", { text: sub_category })
            end
            episodes.each do |ep|
              xml.item { ep.to_xml(xml) } if ep.publish_date_in_past?
            end
          end
        end
      end
    end
  end

  Episode = Struct.new(:title, :media_path, :description, :pubdate, :image_path, :episode_type, :episode_number,
                       :author, :keywords, :guid, :category, :sub_category, :_size_bytes, :duration, :explicit) do
    def pubdate_rfc822
      pubdate.rfc2822
    end

    def publish_date_in_past?
      Time.now > pubdate
    end

    def get_mime_type
      ::Podcast.mimetypes[File.extname(media_path)]
    end

    def to_xml(channel_xml)
      channel_xml.pubDate pubdate_rfc822
      channel_xml.send("itunes:title", title)
      channel_xml.send("title", title)
      channel_xml.description { channel_xml.cdata description }
      channel_xml.send("itunes:summary", description)
      channel_xml.guid(guid)
      channel_xml.enclosure(url: Podcast.declaration.s3["episodes_url"] + media_path, type: get_mime_type,
                            length: _size_bytes)
      # itunes
      channel_xml.send("itunes:image", { href: Podcast.declaration.s3["images_url"] + image_path })
      channel_xml.send("content:encoded") { channel_xml.cdata description }
      channel_xml.send("itunes:duration", duration)
      channel_xml.send("media:content", url: Podcast.declaration.s3["episodes_url"] + media_path, type: get_mime_type,
                                        isDefault: true, medium: "audio") do
        channel_xml.send("media:title", { type: "plain" }, title)
      end
      channel_xml.send("itunes:keywords", keywords)
      channel_xml.send("itunes:episodeType", episode_type)
      channel_xml.send("itunes:episode", episode_number)
      channel_xml.send("itunes:explicit", explicit)
      channel_xml.send("itunes:author", author)
    end
  end

  def self.new_episode(title:, media_path:, description:, pubdate:, image_path:, number:, author:, keywords:, category:, sub_category:, bucket:, _size_bytes:, duration:, episode_type: "full", explicit: "no")
    pubdate = Time.parse(pubdate).utc
    $stderr.write "looking in s3 for episode #{number}:'#{title}' at path episodes/#{media_path}\n"
    s3episode = Podcast::S3Buckets.episodes(bucket: bucket).find { |e| e.path == "episodes/#{media_path}" }

    if s3episode
      if s3episode.guid.nil?
        $stderr.write("Guid is nil for episode #{number}. guid must be present for the xml in the rss feed.")
        abort
      end
      $stderr.write "Found episode #{s3episode}\n"
      guid = s3episode.guid
    else
      warn("could not find episode number #{number} in s3. run and publish without dry run")
    end

    description.gsub!(/\n/, "<br>")

    Episode.new(title, media_path, description, pubdate, image_path, episode_type, number, author, keywords, guid, category,
                sub_category, _size_bytes, duration, explicit)
  end

  def self.new_channel(declaration)
    Channel.new(
      declaration.channel["author"],
      declaration.channel["episodes"],
      declaration.channel["long_description"],
      declaration.channel["short_description"],
      declaration.channel["link"],
      declaration.channel["title"],
      declaration.channel["explicit"],
      declaration.channel["language"],
      declaration.channel["type"],
      declaration.channel["image_path"],
      declaration.channel["keywords"],
      declaration.channel["owner_email"],
      declaration.channel["owner_name"],
      declaration.channel["category"],
      declaration.channel["sub_category"]
    )
  end

  def self.symbolize_keys(hash)
    new_hash = {}
    hash.each do |k, v|
      new_hash[k.to_sym] = v
    end
    new_hash
  end

  def self.converge(conf)
    if conf.dig("channel", "explicit").nil?
      conf["channel"]["explicit"] = "no"
    end

    Podcast.declaration = conf
    channel = new_channel(Podcast.declaration)
    # Add dynamic attributes to episode that should most of the time be inherited from channel, but can be overridden for each episode in the channel's yaml
    channel.episodes.each do |e|
      e["author"] = channel.author unless e.has_key?("author")
      e["image_path"] = channel.image_path unless e["image_path"]
      e["category"] = Podcast.declaration.channel["category"] unless e.key?("category")
      e["sub_category"] = Podcast.declaration.channel["sub_category"] unless e.key?("sub_category")
      e["bucket"] = Podcast.declaration.s3["bucket"]
      e["explicit"] = if !Podcast.declaration.channel["explicit"].nil?
          if e["explicit"].nil?
            e["explicit"] = Podcast.declaration.channel["explicit"]
          end
        end
    end

    # Create new episodes from channel episodes yaml
    channel.episodes = channel
      .episodes
      .map { |e| new_episode(symbolize_keys(e)) }
      .select(&:publish_date_in_past?)

    warn "Publishing XML to local file"
    channel.to_xml
  end
end
