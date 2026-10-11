require "test_helper"
require "json"

# The React islands bundle is built with Node at image-build time only. These
# are file-content checks: no Node, Docker, database or network is used.
class JavascriptBuildContractTest < ActiveSupport::TestCase
  setup { @dockerfile = Rails.root.join("Dockerfile").read }

  def stages
    @dockerfile.split(/^(?=FROM )/).select { |chunk| chunk.start_with?("FROM ") }
  end

  test "the node stage is digest pinned and builds the bundle" do
    node = stages.find { |stage| stage.lines.first.match?(/ AS javascript$/) }

    assert node, "Dockerfile has a javascript stage"
    assert_match %r{\AFROM docker\.io/library/node:22\.\d+\.\d+-slim@sha256:\h{64} AS javascript$}, node
    assert_includes node, "RUN npm ci --ignore-scripts"
    assert_match(/RUN npm run typecheck && npm run build/, node)
  end

  test "only the built bundle crosses from the node stage, and only into the build stage" do
    assert_equal [ "COPY --from=javascript /rails/app/assets/builds/islands.js ./app/assets/builds/islands.js" ],
                 @dockerfile.lines.map(&:strip).grep(/--from=javascript/)

    build = stages.find { |stage| stage.match?(/ AS build$/) }.lines.reject { |line| line.strip.start_with?("#") }.join
    assert_operator build.index("COPY . ."), :<, build.index("--from=javascript")
    assert_operator build.index("--from=javascript"), :<, build.index("assets:precompile")

    final = stages.last
    assert_no_match(/node|npm|--from=javascript/i, final.lines.reject { |line| line.strip.start_with?("#") }.join)
  end

  test "node inputs are not excluded from the build context" do
    ignored = Rails.root.join(".dockerignore").read.lines.map(&:strip)

    assert_includes ignored, "/node_modules/"
    %w[/package.json /package-lock.json /tsconfig.json /app].each { |path| assert_not_includes ignored, path }
  end

  test "npm dependencies are exact versions and the package is private" do
    package = JSON.parse(Rails.root.join("package.json").read)
    versions = package.fetch("dependencies").merge(package.fetch("devDependencies"))

    assert_equal true, package.fetch("private")
    assert_equal %w[@types/react @types/react-dom esbuild react react-dom typescript], versions.keys.sort
    versions.each { |name, version| assert_match(/\A\d+\.\d+\.\d+\z/, version, "#{name} is not pinned exactly") }
  end

  test "typescript is strict and covers only the islands" do
    tsconfig = JSON.parse(Rails.root.join("tsconfig.json").read)

    assert_equal true, tsconfig.dig("compilerOptions", "strict")
    assert_equal true, tsconfig.dig("compilerOptions", "noEmit")
    assert_equal [ "app/frontend/islands/**/*" ], tsconfig.fetch("include")
  end

  test "propshaft does not publish the islands sources" do
    published = Rails.application.assets.load_path.assets.map { |asset| asset.logical_path.to_s }

    assert_empty published.grep(%r{\Aislands/})
    assert_empty published.grep(/\.tsx?\z/)
    assert_includes Rails.root.join("app/frontend/islands").glob("**/*.tsx").map { |path| path.extname }, ".tsx"
  end
end
