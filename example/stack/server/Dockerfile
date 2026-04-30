FROM dart:stable AS build

WORKDIR /build

# Copy aq_schema package
COPY aq_schema/pubspec.yaml aq_schema/
COPY aq_schema/lib aq_schema/lib

# Copy aq_data_layer package
COPY aq_data_layer/pubspec.yaml aq_data_layer/
COPY aq_data_layer/lib aq_data_layer/lib

# Copy server code
COPY aq_data_layer/example/stack/server/pubspec.yaml aq_data_layer/example/stack/server/
COPY aq_data_layer/example/stack/server/main.dart aq_data_layer/example/stack/server/

# Get dependencies and compile
WORKDIR /build/aq_data_layer/example/stack/server
RUN dart pub get
RUN dart compile exe main.dart -o server

FROM debian:bookworm-slim
COPY --from=build /build/aq_data_layer/example/stack/server/server /app/server
EXPOSE 8765
ENTRYPOINT ["/app/server"]
