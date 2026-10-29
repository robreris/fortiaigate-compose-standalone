# Preserve resource addresses when adding conditional creation.
moved {
  from = aws_instance.host
  to   = aws_instance.host[0]
}

moved {
  from = aws_s3_bucket.utility
  to   = aws_s3_bucket.utility[0]
}

moved {
  from = aws_s3_bucket_public_access_block.utility
  to   = aws_s3_bucket_public_access_block.utility[0]
}

moved {
  from = aws_s3_bucket_server_side_encryption_configuration.utility
  to   = aws_s3_bucket_server_side_encryption_configuration.utility[0]
}

moved {
  from = aws_s3_bucket_policy.utility
  to   = aws_s3_bucket_policy.utility[0]
}
