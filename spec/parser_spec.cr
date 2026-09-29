require "./spec_helper"

describe NanoSVG::Parser do
  it "parses a simple rect" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50">
        <rect x="10" y="5" width="40" height="20" fill="#ff0000"/>
      </svg>
    SVG
    img = NanoSVG.parse(svg)
    img.width.should eq(100)
    img.height.should eq(50)
    img.shapes.size.should eq(1)
    shape = img.shapes[0]
    shape.fill.type.color?.should be_true
    # 0xAABBGGRR: R in low byte
    (shape.fill.color & 0xff).should eq(255)
    (shape.fill.color >> 24).should eq(255)
    shape.paths.size.should eq(1)
    (shape.paths[0].npts % 3).should eq(1)
    b = shape.bounds
    b[0].should be_close(10, 0.01)
    b[1].should be_close(5, 0.01)
    b[2].should be_close(50, 0.01)
    b[3].should be_close(25, 0.01)
  end

  it "parses colors" do
    svg = %(<svg width="10" height="10"><rect width="10" height="10" fill="rgb(100%, 0%, 0%)"/></svg>)
    shape = NanoSVG.parse(svg).shapes[0]
    (shape.fill.color & 0xff).should eq(255)
    shape = NanoSVG.parse(%(<svg width="10" height="10"><rect width="10" height="10" fill="#abc"/></svg>)).shapes[0]
    (shape.fill.color & 0xff).should eq(0xaa)
    ((shape.fill.color >> 8) & 0xff).should eq(0xbb)
    ((shape.fill.color >> 16) & 0xff).should eq(0xcc)
    # named color from the full keyword list
    shape = NanoSVG.parse(%(<svg width="10" height="10"><rect width="10" height="10" fill="dodgerblue"/></svg>)).shapes[0]
    ((shape.fill.color >> 16) & 0xff).should eq(255)
  end

  it "converts arcs to cubics" do
    svg = %(<svg width="100" height="100"><circle cx="50" cy="50" r="40"/></svg>)
    img = NanoSVG.parse(svg)
    path = img.shapes[0].paths[0]
    # circle = 4 cubic segments (13 pts) + closing line as a degenerate
    # cubic (3 pts) => 16 points, still 1 + N*3
    path.npts.should eq(16)
  end

  it "applies viewBox scaling" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="100" height="50"><rect x="0" y="0" width="200" height="100" fill="black"/></svg>)
    img = NanoSVG.parse(svg)
    img.shapes[0].bounds[2].should be_close(100, 0.01)
    img.shapes[0].bounds[3].should be_close(50, 0.01)
  end

  it "parses gradients with stops and resolves them late" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
        <defs>
          <linearGradient id="g">
            <stop offset="0" stop-color="#ffffff"/>
            <stop offset="1" stop-color="#000000"/>
          </linearGradient>
        </defs>
        <rect width="10" height="10" fill="url(#g)"/>
      </svg>
    SVG
    shape = NanoSVG.parse(svg).shapes[0]
    shape.fill.type.linear?.should be_true
    grad = shape.fill.gradient.should_not be_nil
    grad.not_nil!.stops.size.should eq(2)
  end

  it "supports <style> classes and display:none" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">
        <style>.a { fill: #123456; } .hidden { display: none; }</style>
        <rect class="a" width="4" height="4"/>
        <rect class="hidden" y="5" width="4" height="4"/>
      </svg>
    SVG
    img = NanoSVG.parse(svg)
    img.shapes.size.should eq(2)
    # 0xAABBGGRR layout: B (#56) in bits 16..23
    ((img.shapes[0].fill.color >> 16) & 0xff).should eq(0x56)
    img.shapes[1].visible?.should be_false
  end

  it "parses transforms" do
    svg = %(<svg width="100" height="100"><g transform="translate(10,20)"><rect width="5" height="5"/></g></svg>)
    img = NanoSVG.parse(svg)
    img.shapes[0].bounds[0].should be_close(10, 0.01)
    img.shapes[0].bounds[1].should be_close(20, 0.01)
  end

  it "keeps npts % 3 == 1 invariant for all paths" do
    Dir["#{__DIR__}/../example_data/*.svg"].each do |f|
      img = NanoSVG.parse_from_file(f)
      img.shapes.each do |s|
        s.paths.each do |p|
          (p.npts % 3).should eq(1), "#{f}: #{p.npts}"
        end
      end
    end
  end
end
