require 'aws-sdk-s3'

if ENV['AWS_S3_REGION'].present?
  Aws.config.update({
      region: ENV['AWS_S3_REGION'],
      credentials: Aws::Credentials.new(ENV['AWS_S3_KEY_ID'], ENV['AWS_S3_ACCESS_KEY'])
  })

  S3_BUCKET = Aws::S3::Resource.new.bucket(ENV['AWS_S3_BUCKET'])
end