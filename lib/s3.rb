require 'open3'
require 'aws-sdk-s3'
require 'json'
require 'time'

# Call:
# Podcast::S3Buckets.episodes
#
# #<struct Podcast::S3Buckets::Episode 
#   path="episodes/draft-stb-2019-03-03-first.mp3", 
#   guid="63f25dfa4743c0d9315d4e5:e75a3fb242f080349a84b2b03119:94ab40aa86624892e0acc802d38", 
#   release_date="2019-03-20"
#   episode_number=1>

module Podcast

  GUID = 'guid'.freeze # the unique id for the podcast episode
  RELEASE_DATE = 'release_date'.freeze # the date after which the episode will be put into the feed
  EPISODE_NUMBER = 'episode_number'.freeze # the chronological number of the episode

  module S3Buckets
    Episode = Struct.new(:path, :guid, :release_date, :episode_number) do
      def valid?
        [path,guid,release_date].all?{|i| i != nil}
      end
      def pubdate
        Time.parse(release_date).utc
      end
    end

    def self.client
      Aws::S3::Client.new
    end

    def self.tag_name(tags, key)
      found = tags.find{|t| t.key == key}
      found.value if found
    end

    def self.create_guid
      passwd = []
      3.times do
        passwd << SecureRandom.uuid.tr('-','')
      end
      passwd.join(':')
    end

    def self.episodes(path_prefix: 'episodes',bucket:)
      ep_list = []
      episodes = client.list_objects(bucket: bucket, prefix: path_prefix).contents

      episodes.select{|e| e.size != 0}&.each do |ep|
        details = client.get_object_tagging(bucket: bucket, key: ep.key).tag_set
        ep_list << Episode.new(ep.key, tag_name(details, GUID), tag_name(details, RELEASE_DATE), tag_name(details, EPISODE_NUMBER).to_i)
      end
      ep_list.select(&:valid?)
    end
  end
end
