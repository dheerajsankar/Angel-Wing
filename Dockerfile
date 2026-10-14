FROM ubuntu:22.04

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG DEBIAN_FRONTEND=noninteractive
# Limit parallel compilation: building Jazzy from source can use substantial RAM.
ARG ROS_BUILD_JOBS=2
# Add hardware/simulation dependencies here or through --build-arg later.
ARG EXTRA_APT_PACKAGES=""

ENV ROS_DISTRO=jazzy \
    ROS_VERSION=2 \
    ROS_PYTHON_VERSION=3 \
    PYTHONUNBUFFERED=1

# Enable Universe before installing development packages from that repository.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg locales software-properties-common \
    && add-apt-repository -y universe \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Development tools and reusable foundations for the custom EKF, guidance,
# controller, safety, mission, and swarm nodes.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build pkg-config git \
        gdb clang clang-format clang-tidy cppcheck \
        libeigen3-dev libyaml-cpp-dev libboost-system-dev libboost-thread-dev \
        libgeographic-dev libasio-dev libtinyxml2-dev \
        libgtest-dev libgmock-dev \
        python3-dev python3-pip python3-venv \
        python3-yaml python3-serial python3-pytest python3-pytest-cov \
        python3-pytest-mock python3-pytest-timeout python3-flake8 \
        iproute2 iputils-ping ${EXTRA_APT_PACKAGES} \
    && rm -rf /var/lib/apt/lists/*

# Jazzy debs target Ubuntu 24.04. On 22.04, use the ROS source build instead.
# https://docs.ros.org/en/jazzy/Installation/Alternatives/Ubuntu-Development-Setup.html
# Use the ROS HTTP APT endpoint; signed-by still verifies repository signatures.
RUN curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" \
        > /etc/apt/sources.list.d/ros2.list \
    && printf '%s\n' 'APT::Update::Error-Mode "any";' \
        > /etc/apt/apt.conf.d/99fail-on-update-error \
    && apt-get update && apt-get install -y --no-install-recommends \
        ros-dev-tools \
    && rosdep init \
    && rosdep update --rosdistro jazzy \
    && rm -rf /var/lib/apt/lists/*

# Build the ROS base plus transforms, custom-interface generation, bag recording,
# lifecycle nodes, and the lint tools used by this project's package manifests.
# Fast DDS is provided by the source workspace; no flight stack is required.
WORKDIR /tmp/ros2_jazzy
RUN mkdir src \
    && vcs import --input https://raw.githubusercontent.com/ros2/ros2/jazzy/ros2.repos src

# ros2.repos omits the variants repository containing ros_base and ros_core.
RUN git clone --depth 1 --branch jazzy https://github.com/ros2/variants.git src/ros2/variants

RUN colcon list --packages-up-to \
        ros_base tf2_ros tf2_geometry_msgs tf2_sensor_msgs \
        rosbag2 rclcpp_lifecycle rosidl_default_generators \
        ament_lint_auto ament_lint_common --paths-only > /tmp/ros-source-paths \
    && apt-get update \
    && rosdep install --from-paths $(cat /tmp/ros-source-paths) \
        --ignore-src --rosdistro jazzy -y \
        --skip-keys "fastcdr rti-connext-dds-6.0.1 urdfdom_headers" \
    && MAKEFLAGS="-j${ROS_BUILD_JOBS}" CMAKE_BUILD_PARALLEL_LEVEL="${ROS_BUILD_JOBS}" \
        colcon build --merge-install --install-base /opt/ros/jazzy \
        --parallel-workers "${ROS_BUILD_JOBS}" \
        --packages-up-to ros_base tf2_ros tf2_geometry_msgs tf2_sensor_msgs \
            rosbag2 rclcpp_lifecycle rosidl_default_generators \
            ament_lint_auto ament_lint_common \
        --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBUILD_TESTING=OFF \
    && rm -rf /tmp/ros2_jazzy /tmp/ros-source-paths /var/lib/apt/lists/*

# Keep project dependencies in each package.xml as the implementation evolves.
# Rebuilding this image will resolve any newly declared dependencies with rosdep.
WORKDIR /workspaces/Angel-Wing
COPY requirements.txt ./requirements.txt
# Retain access to the system Python packages used by ROS and colcon.
RUN python3 -m venv --system-site-packages /opt/angel-wing-venv \
    && /opt/angel-wing-venv/bin/python -m pip install --no-cache-dir -r requirements.txt
ENV PATH="/opt/angel-wing-venv/bin:${PATH}"

COPY src/ src/
RUN source /opt/ros/jazzy/setup.bash \
    && apt-get update \
    && rosdep install --from-paths src --ignore-src --rosdistro jazzy -y \
    && rm -rf /var/lib/apt/lists/*

# Source ROS for both docker commands and interactive development shells.
COPY docker/entrypoint.sh /usr/local/bin/angel-wing-entrypoint
RUN chmod +x /usr/local/bin/angel-wing-entrypoint \
    && echo 'source /opt/ros/jazzy/setup.bash' >> /root/.bashrc \
    && echo 'if [ -f /workspaces/Angel-Wing/install/setup.bash ]; then source /workspaces/Angel-Wing/install/setup.bash; fi' >> /root/.bashrc

ENTRYPOINT ["/usr/local/bin/angel-wing-entrypoint"]
CMD ["bash"]
