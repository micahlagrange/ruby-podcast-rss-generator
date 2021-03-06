require_relative './lib/generate.rb'
require_relative './lib/s3.rb'


cfile = ARGV[0]
unless File.file? cfile
  $stderr.write("You must pass the yml/yaml file as a configuration input.\n")
  abort
end

conf = YAML.load_file(cfile)

conf['channel']['episodes'].each do |e|
  base_dir = conf['media_base_dir'] ? conf['media_base_dir'] : './episodes/'
  bucket = conf['s3']['bucket']

  # Upload episode
  s3episode = Podcast::S3Buckets.episodes(bucket: bucket).find{|se| se.path == "#{base_dir}/#{e['media_path']}"}
  guid = s3episode.guid ? s3episode.guid : Podcast::S3Buckets.create_guid if s3episode
  $stderr.write("===============================\n")
  $stderr.write("NOTE: Uploading episode #{e}\n")
  $stderr.write("===============================\n")
  resp = Podcast::S3Buckets.upload_episode(
    bucket: bucket,
    audio_file: "#{base_dir}#{e['media_path']}",
    guid: guid,
    pubdate: e['pubdate'],
    episode_number: e['number']
  )
  p resp
end

feed_xml = Podcast.converge(conf).to_xml
File.write('podcast.xml', feed_xml)

$stderr.write("Writing podcast xml to amazon\n")
Podcast::S3Buckets.upload_podcast_xml(bucket: conf['s3']['bucket'], xml_file: 'podcast.xml', name: 'podcast.xml')
