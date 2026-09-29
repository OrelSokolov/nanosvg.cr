require "./spec_helper"

describe NanoSVG::Rasterizer do
  it "rasterizes a filled rect" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect x="5" y="5" width="10" height="10" fill="#ff0000"/></svg>)
    img = NanoSVG.parse(svg)
    px = NanoSVG::Rasterizer.rasterize(img, 0.0f32, 0.0f32, 1.0f32, 20, 20)
    px.size.should eq(20*20*4)
    # center pixel: opaque red
    i = (10*20 + 10)*4
    px[i].should eq(255)      # R
    px[i+1].should eq(0)      # G
    px[i+2].should eq(0)      # B
    px[i+3].should eq(255)    # A
    # corner pixel: transparent
    i = (1*20 + 1)*4
    px[i+3].should eq(0)
  end

  it "rasterizes a stroked line" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><line x1="2" y1="10" x2="18" y2="10" stroke="#00ff00" stroke-width="4"/></svg>)
    img = NanoSVG.parse(svg)
    px = NanoSVG::Rasterizer.rasterize(img, 0.0f32, 0.0f32, 1.0f32, 20, 20)
    i = (10*20 + 10)*4
    px[i+1].should eq(255) # G
    px[i+3].should eq(255) # A
  end

  it "rasterizes a linear gradient" do
    svg = <<-SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="20" height="20">
        <defs><linearGradient id="g">
          <stop offset="0" stop-color="#000000"/>
          <stop offset="1" stop-color="#ffffff"/>
        </linearGradient></defs>
        <rect width="20" height="20" fill="url(#g)"/>
      </svg>
    SVG
    img = NanoSVG.parse(svg)
    px = NanoSVG::Rasterizer.rasterize(img, 0.0f32, 0.0f32, 1.0f32, 20, 20)
    left = px[(10*20 + 2)*4]
    right = px[(10*20 + 17)*4]
    left.should be < 64
    right.should be > 192
  end

  it "applies opacity" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10" fill="#ffffff" opacity="0.5"/></svg>)
    img = NanoSVG.parse(svg)
    px = NanoSVG::Rasterizer.rasterize(img, 0.0f32, 0.0f32, 1.0f32, 10, 10)
    i = (5*10 + 5)*4 + 3
    px[i].to_i32.should be_close(128, 2)
  end

  it "rasterizes real files without crashing" do
    Dir["#{__DIR__}/../example_data/*.svg"].each do |f|
      img = NanoSVG.parse_from_file(f)
      h = 64
      w = [(img.width * h / img.height).round.to_i32, 1].max
      px = NanoSVG::Rasterizer.rasterize(img, 0.0f32, 0.0f32, h.to_f32 / img.height, w, h)
      px.size.should eq(w*h*4)
    end
  end
end
