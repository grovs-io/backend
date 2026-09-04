require 'aws-sdk-s3'

if ENV['AWS_S3_REGION'].present?
  config = { region: ENV['AWS_S3_REGION'] }

  # Aws::Credentials.new(nil, nil) is not a no-op: it blocks the SDK's default
  # provider chain, so an ECS/EKS task IAM role would never be picked up.
  if ENV['AWS_S3_KEY_ID'].present? && ENV['AWS_S3_ACCESS_KEY'].present?
    config[:credentials] = Aws::Credentials.new(ENV['AWS_S3_KEY_ID'], ENV['AWS_S3_ACCESS_KEY'])
  end

  Aws.config.update(config)

  S3_BUCKET = Aws::S3::Resource.new.bucket(ENV['AWS_S3_BUCKET'])
end