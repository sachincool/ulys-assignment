FROM golang:1.25-alpine AS build
WORKDIR /src
COPY apps/api/go.mod apps/api/go.sum ./
RUN go mod download
COPY apps/api/ ./
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false \
    go build -trimpath -ldflags="-s -w" \
    -o /out/api ./cmd/api

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
# Ship apps/web/index.html alongside the binary so the api can serve it
# at GET / (same-origin → no mixed-content block from a browser-loaded
# page calling /work over HTTP).
COPY apps/web/index.html /web/index.html
USER nonroot:nonroot
ENV PORT=8080 INDEX_HTML=/web/index.html
EXPOSE 8080
ENTRYPOINT ["/api"]
