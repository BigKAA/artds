#!/bin/bash
# Build script for 389ds-exporter Docker image

set -e

# Configuration
IMAGE_NAME="artds/389ds-exporter"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
REGISTRY="${DOCKER_REGISTRY:-docker.io}"
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
VCS_REF=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}🏗️  Building Docker image: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}${NC}"
echo -e "${BLUE}📅 Build date: ${BUILD_DATE}${NC}"
echo -e "${BLUE}🔖 VCS ref: ${VCS_REF}${NC}"

# Build the image
docker build \
    --build-arg BUILD_DATE="${BUILD_DATE}" \
    --build-arg VCS_REF="${VCS_REF}" \
    -t ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} \
    .

# Tag as latest
docker tag ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:latest

echo -e "${GREEN}✅ Image built successfully${NC}"
echo -e "${GREEN}   ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}${NC}"
echo -e "${GREEN}   ${REGISTRY}/${IMAGE_NAME}:latest${NC}"

# Optional: Push to registry
if [ "$PUSH" = "true" ]; then
    echo -e "${BLUE}📤 Pushing to registry...${NC}"
    docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
    docker push ${REGISTRY}/${IMAGE_NAME}:latest
    echo -e "${GREEN}✅ Push completed${NC}"
else
    echo -e "${BLUE}💡 To push to registry, run: PUSH=true ./build.sh${NC}"
fi

# Show image info
echo ""
echo -e "${BLUE}📊 Image information:${NC}"
docker images ${REGISTRY}/${IMAGE_NAME} --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
