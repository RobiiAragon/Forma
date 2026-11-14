#include "FormaRadialProjection.h"
#include <iomanip>
#include <iostream>

// Stream projected pixel coordinates through exactly the header used by the
// texture worker, so native-LUT parity can be checked independently of Python.
int main(int argc, char** argv) {
    try {
        if (argc != 4) throw std::runtime_error("Usage: verify-radial IMAGE WIDTH HEIGHT < points.txt");
        FormaRadialProjection model;
        model.load_optional(argv[1], std::stoi(argv[2]), std::stoi(argv[3]));
        if (!model.enabled()) throw std::runtime_error("No native LUT was loaded.");
        std::cout << std::setprecision(17);
        float x, y;
        while (std::cin >> x >> y) {
            model.project(x, y);
            std::cout << x << ' ' << y << '\n';
        }
        return 0;
    } catch (std::exception const& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
