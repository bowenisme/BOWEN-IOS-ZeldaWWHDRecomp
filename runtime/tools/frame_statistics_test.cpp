#include "../src/platform/ios/frame_statistics.h"
#include <cassert>
#include <limits>
#include <cstdio>
using namespace ios::pacing;
bool near(double a, double b) { return std::abs(a - b) < 1e-5; }
int main() {
    FrameHistory h;
    double t = 10;
    h.add(t, 1);
    for (int i = 0; i < 1000; ++i) { t += 1.0/60; h.add(t, 1); }
    auto s = h.summarize(t, 60);
    assert(s.samples == 1000 && near(s.fps, 60) && near(s.low1, 60) && near(s.low01, 60));
    assert(s.longFrames == 0 && near(s.averageMs, 1000.0/60));
    h.add(t, 1); h.add(t-1, 1); h.add(0, 1); h.add(std::numeric_limits<double>::quiet_NaN(), 1);
    assert(h.summarize(t, 60).samples == 1000);
    h.reset(); t=10; h.add(t, 1);
    for (int i=0; i<999; ++i) { t+=1.0/60; h.add(t, 1); }
    assert(h.summarize(t, 60).low01 < 0); // insufficient 0.1% sample
    t+=.1; h.add(t, 1); s=h.summarize(t, 60);
    assert(near(s.low1, 40) && near(s.low01, 10)); // average worst durations, not percentile FPS
    assert(near(s.p99Ms,1000.0/60) && near(s.p999Ms,1000.0/60));
    assert(near(s.maximumMs,100) && s.longFrames==1 && near(s.minimumFPS,10));
    assert(near(s.fps,1000.0/(999*(1000.0/60)+100)*1000));
    assert(near(*std::max_element(s.graph.begin(),s.graph.end()),100)); // binning preserves hitch
    assert(h.summarize(t+3,60).samples==0); // no stale performance when no frames arrive
    h.add(t+.02, 2); assert(h.summarize(t+.02,60).samples==0); // demand generation reset
    h.reset(); t=10; h.add(t,2);
    for(int i=0;i<20000;++i) { t+=1.0/120; h.add(t,2); }
    s=h.summarize(t,120);
    assert(s.samples>=7199&&s.samples<=7201&&near(s.fps,120)); // wrap and rolling expiry
    h.reset(); t=10; h.add(t,3);
    for(int i=0;i<200;++i) { t+=1.0/30; h.add(t,3); }
    assert(h.summarize(t,30).longFrames==0&&h.summarize(t,60).longFrames==200);
    h.reset(); t=10; h.add(t,4);
    for(int i=0;i<100;++i) { t+=.025; h.add(t,4); t+=1.0/120; h.add(t,4); }
    s=h.summarize(t,60);
    assert(s.catchUpPairs==100 && near(s.fps,60) && near(s.low1,40));
    assert(h.summarize(t,30).catchUpPairs==0); // thresholds follow the requested frame budget
    h.reset(); t=10; h.add(t,5); t+=1.0/120; h.add(t,5);
    assert(h.summarize(t,60).catchUpPairs==0); // short interval alone is not a paired catch-up
    puts("frame_statistics_test: actual intervals, low formulas, warm-up, hitches, reset and rolling window passed");
}
