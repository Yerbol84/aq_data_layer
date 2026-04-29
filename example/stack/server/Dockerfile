FROM dart:stable AS build

WORKDIR /build

# Copy aq_schema package (sibling directory)
COPY aq_schema/pubspec.yaml aq_schema/
COPY aq_schema/lib aq_schema/lib

# Copy dart_vault package
COPY dart_vault_package/pubspec.yaml dart_vault_package/
COPY dart_vault_package/lib dart_vault_package/lib

# Copy server code
COPY dart_vault_package/example/stack/server/pubspec.yaml dart_vault_package/example/stack/server/
COPY dart_vault_package/example/stack/server/main.dart dart_vault_package/example/stack/server/

# Get dependencies and compile
WORKDIR /build/dart_vault_package/example/stack/server
RUN dart pub get
RUN dart compile exe main.dart -o server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /build/dart_vault_package/example/stack/server/server /app/server
EXPOSE 8765
ENTRYPOINT ["/app/server"]
