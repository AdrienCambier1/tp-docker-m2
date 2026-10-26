variable "REGISTRY" {
  default = "ghcr.io/adriencambier1"
}

variable "IMAGE" {
  default = "tp-docker-m2-api"
}

variable "VERSION" {
  default = "dev"
}

variable "TAGS" {
  default = "${VERSION}"
}

variable "PIP_TOKEN_FILE" {
  default = "secrets/pip_token.txt"
}

variable "GITHUB_ACTIONS" {
  default = "false"
}

function "cache_from" {
  params = [scopes]
  result = GITHUB_ACTIONS == "true" ? [for s in scopes : "type=gha,scope=${s}"] : []
}

function "cache_to" {
  params = [scope]
  result = GITHUB_ACTIONS == "true" ? ["type=gha,scope=${scope},mode=max"] : []
}

group "default" {
  targets = ["api"]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  target     = "runtime"
  secret     = ["id=pip_token,src=${PIP_TOKEN_FILE}"]
  labels = {
    "org.opencontainers.image.title"   = "${IMAGE}"
    "org.opencontainers.image.version" = "${VERSION}"
  }
}

target "api" {
  inherits   = ["_common"]
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = [for t in split(",", TAGS) : "${REGISTRY}/${IMAGE}:${trimspace(t)}"]
  cache-from = cache_from(["api-multi", "api-amd64"])
  cache-to   = cache_to("api-multi")
}

target "api-ci" {
  inherits   = ["_common"]
  platforms  = ["linux/amd64"]
  tags       = ["${IMAGE}:ci"]
  output     = ["type=docker"]
  cache-from = cache_from(["api-amd64", "api-multi"])
  cache-to   = cache_to("api-amd64")
}
