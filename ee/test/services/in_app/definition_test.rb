require "test_helper"
require_relative "../../support/in_app_shared_cases"

class InAppDefinitionTest < ActiveSupport::TestCase
  include InAppFixtures
  fixtures :instances, :projects, :visitors, :devices

  setup do
    @project = projects(:one)
    clear_in_app_stamps(@project)
  end

  def html_campaign(html, layout: "modal", **attrs)
    in_app_campaign(@project, template: "html", content: { "html" => html, "layout" => layout }, **attrs)
  end

  test "every link_rule case from the shared contract" do
    InAppSharedCases.file.fetch("link_rule").each do |kase|
      expected = kase["expect"] == "allowed"
      assert_equal expected, InAppDefinition.link_allowed?(kase["input"]), kase["name"]
    end
  end

  test "every html_parsing case from the shared contract" do
    base = html_campaign("<div>Hi</div>").definition
    InAppSharedCases.file.fetch("html_parsing").each do |kase|
      content = base["content"].except("html", "layout").merge(kase["content"])
      problems = InAppDefinition.problems(base.merge("content" => content))
      kase["expect"] == "valid" ? assert_empty(problems, kase["name"]) : assert_not_empty(problems, kase["name"])
    end
  end

  test "resource_allowed? requires https, plus data:image only for images" do
    assert InAppDefinition.resource_allowed?("https://cdn.example/a.png", image: false)
    assert_not InAppDefinition.resource_allowed?("http://cdn.example/a.png", image: false)
    assert InAppDefinition.resource_allowed?("http://localhost:3000/rails/active_storage/a.png", image: true)
    assert InAppDefinition.resource_allowed?("http://api.lvh.me:3000/a.mp4", image: false)
    assert_not InAppDefinition.resource_allowed?("http://localhost.evil.com/a.png", image: true)
    assert InAppDefinition.resource_allowed?("data:image/png;base64,abc", image: true)
    assert_not InAppDefinition.resource_allowed?("data:image/png;base64,abc", image: false)
    assert_not InAppDefinition.resource_allowed?("https://#a.png", image: true)
  end

  test "resource_allowed? refuses local http hosts in production" do
    Rails.stub(:env, ActiveSupport::EnvironmentInquirer.new("production")) do
      assert_not InAppDefinition.resource_allowed?("http://localhost:3000/rails/active_storage/a.png", image: true)
      assert_not InAppDefinition.resource_allowed?("http://api.lvh.me:3000/a.mp4", image: false)
      assert InAppDefinition.resource_allowed?("https://cdn.example/a.png", image: false)
    end
  end

  test "a field inside a URL attribute is refused, naming the attribute and value, and nothing else" do
    campaign = html_campaign('<a href="{{ user.id }}">Go</a>')
    problems = InAppDefinition.problems(campaign.definition)
    message = problems.find { |p| p.include?("{{") }
    assert message
    assert_includes message, 'href="{{ user.id }}"'
    assert_includes message, "build personalized URLs with grovs.user"
    assert_equal [message], problems
  end

  test "the field-in-url message names only the first three offenders" do
    html = (1..5).map { |i| "<a href=\"{{ user.id#{i} }}\">#{i}</a>" }.join
    problems = InAppDefinition.problems(html_campaign(html).definition)
    message = problems.find { |p| p.include?("{{") }
    assert_equal 3, message.scan("href=").size
  end

  test "line breaks and freeform {{ inside the html body are allowed" do
    html = "<html>\n<body>\n  {{ not a real field }}\n</body>\n</html>"
    assert_empty InAppDefinition.problems(html_campaign(html).definition)
  end

  test "html cannot hold a question" do
    campaign = html_campaign("<p>hi</p>")
    campaign.content = campaign.content.merge("question" => STARS)
    assert_equal ["This kind of message cannot hold a question"], InAppDefinition.problems(campaign.definition)
  end

  test "blank html is refused" do
    assert_includes InAppDefinition.problems(html_campaign("").definition), "The HTML cannot be empty"
  end

  test "html over 64 KB raw bytes is refused even when under the schema's character bound" do
    # multi-byte characters keep the character count under 65536 while pushing the byte count over it; InAppCampaign.new
    # rather than the html_campaign/create! helper, since the model itself now refuses this before problems() runs
    html = "<p>#{'é' * 40_000}</p>"
    campaign = InAppCampaign.new(project: @project, name: "Big", template: "html", content: { "html" => html, "layout" => "modal" },
                                  triggers: InAppFixtures::TRIGGERS.map(&:dup))
    assert_includes InAppDefinition.problems(campaign.definition), "The HTML is larger than 64 KB"
  end

  test "html that fails to parse is refused" do
    campaign = html_campaign("<div>" * 500)
    assert_includes InAppDefinition.problems(campaign.definition), "The HTML could not be read"
  end

  test "a <base> tag is refused" do
    campaign = html_campaign('<base href="https://evil.example/">')
    assert_includes InAppDefinition.problems(campaign.definition), "The HTML cannot use a <base> tag"
  end

  test "a meta refresh is refused" do
    campaign = html_campaign('<meta http-equiv="refresh" content="0;url=https://evil.example">')
    assert_includes InAppDefinition.problems(campaign.definition), 'The HTML cannot use <meta http-equiv="refresh">'
  end

  test "a disallowed link is refused" do
    campaign = html_campaign('<a href="javascript:alert(1)">x</a>')
    assert_includes InAppDefinition.problems(campaign.definition), "The HTML links to an address that is not allowed"
  end

  test "a disallowed resource is refused" do
    campaign = html_campaign('<img src="http://insecure.example/a.png">')
    assert_includes InAppDefinition.problems(campaign.definition), "The HTML loads a resource that is not allowed"
  end

  test "a srcset data URI candidate is allowed, its internal comma is not mistaken for a separator" do
    html = '<img src="https://cdn.example/a.png" srcset="data:image/png;base64,AAAA 1x, https://cdn.example/b.png 2x">'
    assert_empty InAppDefinition.problems(html_campaign(html).definition)
  end

  test "a srcset http candidate is refused" do
    html = '<img src="https://cdn.example/a.png" srcset="https://cdn.example/a.png 1x, http://cdn.example/b.png 2x">'
    assert_includes InAppDefinition.problems(html_campaign(html).definition), "The HTML loads a resource that is not allowed"
  end

  test "a disallowed poster is refused, an https one is allowed" do
    bad = html_campaign('<video poster="http://insecure.example/a.png"></video>')
    assert_includes InAppDefinition.problems(bad.definition), "The HTML loads a resource that is not allowed"
    good = html_campaign('<video poster="https://cdn.example/a.png" width="10" height="10"></video>')
    assert_empty InAppDefinition.problems(good.definition)
  end

  test "style url() is matched case-insensitively" do
    campaign = html_campaign('<div style="background: URL(\'http://insecure.example/a.png\')"></div>')
    assert_includes InAppDefinition.problems(campaign.definition), "The HTML loads a resource that is not allowed"
  end

  test "style url() allows data: images, quoted with ) and the other quote inside" do
    svg = %{data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg'><rect fill='url(#g)'/></svg>}
    html = %{<div style='background: url("#{svg.gsub("'", '&#39;')}") , url(https://cdn.example/a.png)'></div>}
    assert_empty InAppDefinition.problems(html_campaign(html).definition)
    assert_empty InAppDefinition.problems(html_campaign(%{<div style="background: url('data:image/png;base64,AA)A')"></div>}).definition)
  end

  test "style url() hidden behind a quote, a comment or an escape is still checked" do
    [%{<div style="background: url('https://cdn.example/a.png?)'), url(http://insecure.example/b.png)"></div>},
     %{<div style="background: url(/**/'http://insecure.example/a.png')"></div>},
     %{<div style="background: url(&quot;h\\ttp://insecure.example/a.png&quot;)"></div>},
     %{<div style="background: url(data:text/html,x)"></div>},
     %{<div style="background: url('http://insecure.example/a.png"></div>}].each do |html|
      assert_includes InAppDefinition.problems(html_campaign(html).definition), "The HTML loads a resource that is not allowed", html
    end
  end

  test "a <link href> is linted as a resource: https only, no custom schemes" do
    bad = html_campaign('<link href="http://insecure.example/a.css" rel="stylesheet">')
    assert_includes InAppDefinition.problems(bad.definition), "The HTML loads a resource that is not allowed"
    good = html_campaign('<link href="https://cdn.example/a.css" rel="stylesheet">')
    assert_empty InAppDefinition.problems(good.definition)
  end

  test "data-grovs-url is linted with the link rule and the field rule" do
    bad = html_campaign('<button data-grovs-action="open" data-grovs-url="javascript:alert(1)">Go</button>')
    assert_includes InAppDefinition.problems(bad.definition), "The HTML links to an address that is not allowed"
    good = html_campaign('<button data-grovs-action="open" data-grovs-url="https://cdn.example">Go</button>')
    assert_empty InAppDefinition.problems(good.definition)
    field = html_campaign('<button data-grovs-action="open" data-grovs-url="{{ user.id }}">Go</button>')
    problems = InAppDefinition.problems(field.definition)
    assert_equal 1, problems.size
    assert_includes problems.first, "data-grovs-url"
  end

  test "an unknown layout is refused by the schema" do
    assert_not_empty InAppDefinition.problems(html_campaign("<p>hi</p>", layout: "fullscreen").definition)
  end

  test "size is measured without the html body, so a large html passes while other bloat still fails" do
    small = html_campaign("<p>#{'a' * (60 * 1024)}</p>")
    assert_empty InAppDefinition.problems(small.definition)

    heavy_conditions = Array.new(10) { { "type" => "user_attribute", "key" => "k", "op" => "eq", "value" => "v" * 2_000 } }
    big = InAppCampaign.new(project: @project, name: "Big", template: "html", content: { "html" => "<p>hi</p>", "layout" => "modal" },
                             triggers: InAppFixtures::TRIGGERS.map(&:dup), conditions: heavy_conditions)
    assert_not big.valid?
    assert_includes big.errors[:base], "The campaign is larger than 16 KB"
  end

  test "an alert keeps its title, message and button labels short, and other templates do not" do
    long = { "title" => "t" * 81, "message" => "m" * 301,
             "buttons" => [{ "id" => "b1", "text" => "b" * 31, "action" => { "type" => "close" } }] }
    alert = in_app_campaign(@project, template: "alert", content: long)
    assert_equal ["An alert title cannot be longer than 80 characters",
                  "An alert message cannot be longer than 300 characters",
                  "An alert button label cannot be longer than 30 characters"], InAppDefinition.problems(alert.definition)

    at_limit = long.merge("title" => "t" * 80, "message" => "m" * 300,
                          "buttons" => [long["buttons"][0].merge("text" => "b" * 30)])
    assert_empty InAppDefinition.problems(in_app_campaign(@project, template: "alert", content: at_limit).definition)
    assert_empty InAppDefinition.problems(in_app_campaign(@project, template: "interstitial", content: long).definition)
  end
end
