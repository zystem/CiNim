# the core's token: the key of the shard, the four calls it makes, nothing else
path "transit/encrypt/cinim-shard" { capabilities = ["update"] }
path "transit/decrypt/cinim-shard" { capabilities = ["update"] }
path "transit/rewrap/cinim-shard"  { capabilities = ["update"] }
path "transit/keys/cinim-shard"    { capabilities = ["read"] }
