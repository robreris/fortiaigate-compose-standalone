#!/usr/bin/env bash
# Load the ten Fortinet component archives and publish exactly the tags CLI 0.6.3 pulls.
set -Eeuo pipefail

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ $# != 4 ]]; then
  echo "Usage: AWS_DEFAULT_REGION=us-west-2 $0 REGISTRY/PREFIX VERSION BUILD ARCHIVE_DIR" >&2
  exit 2
fi
registry_path=${1%/}
version=$2
build=$3
archive_dir=$4
[[ $registry_path =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com(\.cn)?/[a-z0-9/_-]+$ ]] || die "Use the Terraform registry_path output without https://."
[[ $version =~ ^[0-9]+(\.[0-9]+)+$ && $build =~ ^[0-9]+$ ]] || die "Use a numeric version and build; preserve leading zeros in the archive build."
[[ -d $archive_dir ]] || die "Archive directory does not exist: $archive_dir"
region=${AWS_DEFAULT_REGION:-${AWS_REGION:-}}
[[ -n $region ]] || die "Set AWS_DEFAULT_REGION to the Terraform deployment region."
command -v aws >/dev/null || die "Install the AWS CLI."
command -v docker >/dev/null || die "Install Docker and enable access for your current user."
command -v jq >/dev/null || die "Install jq."
docker info >/dev/null

components=(api webui llm-gateway logd license_manager guardrail guardrail-scanner custom-triton faig-models vllm-server)
declare -A archives tags
for component in "${components[@]}"; do
  base="$archive_dir/FAIG_$component-V$version-build$build-FORTINET.tar"
  if [[ -f $base ]]; then
    archives[$component]=$base
  elif [[ -f $base.gz ]]; then
    archives[$component]=$base.gz
  else
    die "Missing $base[.gz]. The deployment-utility archive does not contain application images."
  fi
  case "$component" in
    custom-triton) tags[$component]=25.11-onnx-trt-agt-rpt-s1 ;;
    faig-models) tags[$component]=0.0.5-s1 ;;
    vllm-server) tags[$component]=0.28.0-rpt-s1 ;;
    *) tags[$component]="V$version-build$build" ;;
  esac
done

# All archives must exist before any upload. Immutable tags make changes explicit.
registry=${registry_path%%/*}
aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$registry"
for component in "${components[@]}"; do
  destination="$registry_path/$component:${tags[$component]}"
  repository="${registry_path#*/}/$component"
  # Only ImageNotFoundException means a new tag; preserve auth/network errors.
  tag_exists=false
  if existing=$(aws ecr describe-images --region "$region" --registry-id "${registry%%.*}" \
      --repository-name "$repository" --image-ids "imageTag=${tags[$component]}" 2>&1); then
    tag_exists=true
  elif [[ $existing != *ImageNotFoundException* ]]; then
    die "Could not check $destination: $existing"
  fi

  printf '\nLoading %s\n' "${archives[$component]}"
  load_output=$(docker load --input "${archives[$component]}" 2>&1) || die "$load_output"
  printf '%s\n' "$load_output"
  mapfile -t loaded_refs < <(printf '%s\n' "$load_output" | sed -n 's/^Loaded image: //p' | sort -u)
  [[ ${#loaded_refs[@]} == 1 ]] || die "Expected exactly one named image in ${archives[$component]}; inspect this archive manually."
  source_ref=${loaded_refs[0]}
  platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$source_ref")
  [[ $platform == linux/amd64 ]] || die "$source_ref is $platform; G6e requires linux/amd64."
  if [[ $tag_exists == true ]]; then
    manifest=$(aws ecr batch-get-image --region "$region" --registry-id "${registry%%.*}" \
      --repository-name "$repository" --image-ids "imageTag=${tags[$component]}" \
      --query 'images[0].imageManifest' --output text)
    remote_config=$(printf '%s' "$manifest" | jq -er '.config.digest')
    local_config=$(docker image inspect --format '{{.Id}}' "$source_ref")
    [[ $remote_config == "$local_config" ]] || die "$destination already contains a different image. Use a new repository prefix; do not overwrite pinned GPU tags."
    printf 'Verified existing image: %s\n' "$destination"
    continue
  fi
  docker tag "$source_ref" "$destination"
  docker push "$destination"
done
printf '\nPublished all 10 images. Wizard: registry=%s version=%s build=%s tag-pattern=V{version}-build{build}\n' \
  "$registry_path" "$version" "$build"
