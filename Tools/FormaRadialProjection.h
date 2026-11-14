#ifndef FORMA_RADIAL_PROJECTION_H
#define FORMA_RADIAL_PROJECTION_H

#include <algorithm>
#include <cmath>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

// Optional native radial projection for mvs-texturing. Coordinates are pixel
// centers with (0,0) at the top-left pixel, after MVE's -0.5 convention correction.
// This maps a pinhole projection to a measured photo pixel; it never rewrites,
// resizes, crops, or undistorts the photograph.
class FormaRadialProjection {
public:
    void load_optional(std::string const& image_path, int width, int height) {
        std::size_t dot = image_path.find_last_of('.');
        std::string path = image_path.substr(0, dot) + ".forma-lut";
        std::ifstream input(path.c_str());
        if (!input) return;
        std::string magic;
        int recorded_width = 0, recorded_height = 0;
        std::size_t count = 0;
        input >> magic >> recorded_width >> recorded_height >> cx >> cy >> rmax >> count;
        if (!input || magic != "FORMA_RADIAL_LUT_V1" || recorded_width != width ||
            recorded_height != height || count < 2 || !std::isfinite(cx) ||
            !std::isfinite(cy) || !std::isfinite(rmax) || rmax <= 0 ||
            cx < 0 || cy < 0 || cx > width - 1 || cy > height - 1)
            throw std::runtime_error("Invalid Forma radial LUT header: " + path);
        double expected = std::hypot(std::max(cx, width - cx), std::max(cy, height - cy));
        if (std::abs(rmax - expected) > 1e-7 * expected)
            throw std::runtime_error("Forma radial LUT radius disagrees with photo dimensions: " + path);
        // Read incrementally; a corrupt declared count cannot preallocate memory.
        for (std::size_t i = 0; i < count; ++i) {
            double value = 0;
            if (!(input >> value) || !std::isfinite(value) || value <= -1)
                throw std::runtime_error("Invalid Forma radial LUT sample: " + path);
            values.push_back(value);
        }
        std::string extra;
        if (input >> extra) throw std::runtime_error("Unexpected Forma radial LUT data: " + path);
        // A physical radial camera must preserve radial ordering throughout each
        // piecewise-linear magnification segment, including between LUT samples.
        double step = rmax / (values.size() - 1);
        for (std::size_t i = 0; i + 1 < values.size(); ++i) {
            double r = step * i, slope = (values[i + 1] - values[i]) / step;
            double start_derivative = 1 + values[i] + r * slope;
            double end_derivative = 1 + values[i + 1] + (r + step) * slope;
            if (start_derivative <= 0 || end_derivative <= 0)
                throw std::runtime_error("Non-monotonic Forma radial LUT: " + path);
        }
    }

    void project(float& x, float& y) const {
        if (values.empty() || !std::isfinite(x) || !std::isfinite(y)) return;
        double dx = double(x) - cx, dy = double(y) - cy;
        double coordinate = std::hypot(dx, dy) * (values.size() - 1) / rmax;
        double magnification = values.back();
        if (coordinate < values.size() - 1) {
            std::size_t index = static_cast<std::size_t>(coordinate);
            double fraction = coordinate - index;
            magnification = values[index] * (1 - fraction) + values[index + 1] * fraction;
        }
        x = static_cast<float>(cx + dx * (1 + magnification));
        y = static_cast<float>(cy + dy * (1 + magnification));
    }

    bool enabled() const { return !values.empty(); }

private:
    double cx = 0, cy = 0, rmax = 0;
    std::vector<double> values;
};

#endif
