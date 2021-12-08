require_relative "./lib/generate.rb"
require_relative "./lib/s3.rb"
require "time"

options = { dry_run: false }

options[:dry_run] = true if ARGV.include?("--dry-run")

cfile = ARGV[0]
if cfile
  unless File.file? cfile
    $stderr.write("You must pass the yml/yaml file as a configuration input.\n")
    abort
  end
  conf = YAML.load_file(cfile)
end

abort("invalid yaml or missing file #{cfile}") if conf.nil?

require "json-schema"

# Abort if the same number, OR same title, OR same pubdate are on more than 1 file
%w[number title pubdate].each do |uid|
  abort("You cannot use the same '#{uid}' on more than 1 episode! Don't change an oldie, change the new one") unless conf["channel"]["episodes"].map { |e| e[uid] }.uniq.length == conf["channel"]["episodes"].map { |e| e[uid] }.length
end

errors = JSON::Validator.fully_validate(JSON.parse(File.read("lib/schema.json")), conf)
abort(errors.to_s) if errors.size > 0

conf["channel"]["episodes"].each_with_index do |e, idx|
  base_dir = conf["media_base_dir"] ? conf["media_base_dir"] : "./episodes/"
  bucket = conf["s3"]["bucket"]

  all_s3episodes = Podcast::S3Buckets.episodes(bucket: bucket)
  s3episode = all_s3episodes.find { |se| se.episode_number == e["number"]  }
  guid = "e#{e["number"]}_#{e["pubdate"].tr(":", "-")}"

  # add file length in bytes
  conf["channel"]["episodes"][idx]["_size_bytes"] = File.size(base_dir + e["media_path"])

  if !s3episode || options[:force]
    # Upload episode
    $stderr.write("===============================\n")
    $stderr.write("NOTE: Uploading episode #{e}\n")
    $stderr.write("===============================\n")

    resp = Podcast::S3Buckets.upload_episode(
      bucket: bucket,
      audio_file: "#{base_dir}#{e["media_path"]}",
      guid: guid,
      pubdate: e["pubdate"],
      episode_number: e["number"],
      mime_type: ::Podcast.mimetypes[File.extname(e["media_path"])],
    )
    puts resp
  end
end

feed_xml = Podcast.converge(conf).to_xml
File.write("podcast.xml", feed_xml)

warn "Wrote episode to #{Dir.pwd}/podcast.xml"

$stderr.write("Writing podcast xml to amazon\n")
Podcast::S3Buckets.upload_podcast_xml(bucket: conf["s3"]["bucket"], xml_file: "podcast.xml", name: "podcast.xml")
Podcast::S3Buckets.upload_podcast_xml(bucket: conf["s3"]["bucket"], xml_file: "podcast.xml", name: "feed")

cache_clear_string = "aws cloudfront create-invalidation --distribution-id #{conf["cloudfront"]["distribution_id"]} --paths /feed /podcast.xml" if conf.dig("cloudfront", "distribution_id")
warn cache_clear_string
resp = `#{cache_clear_string}`
warn JSON.generate(JSON.parse(resp))
warn "\nCache cleared. Use the above aws cli command again if you want to clear cache if you have a cloudfront distrubution."
