#!/bin/bash

if ! [ $(id -u) = 0 ]; then
   echo "The script need to be run as root." >&2
   exit 1
fi

base_dir=$(cd $(dirname $0); pwd)

# # Disable firewalld if exists
# systemctl stop firewalld
# systemctl disable firewalld

# # turn off selinux
# setenforce 0
# sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config

# turn off swap (kubelet will fail to start if swap is enabled)
swapoff -a
sed -i 's/.*swap.*/#&/' /etc/fstab

# 转发 IPv4 并让 iptables 看到桥接流
modules_load_k8s="/etc/modules-load.d/k8s.conf"
if [ -e "${modules_load_k8s}" ]; then
  rm -f "${modules_load_k8s}"
fi
cat <<EOF | sudo tee ${modules_load_k8s}
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
lsmod | grep br_netfilter #验证br_netfilter模块
# 设置所需的 sysctl 参数，参数在重新启动后保持不变
sysctl_k8s="/etc/sysctl.d/k8s.conf"
if [ -e "${sysctl_k8s}" ]; then
  rm -f "${sysctl_k8s}"
fi
cat <<EOF | sudo tee ${sysctl_k8s}
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
# 应用 sysctl 参数而不重新启动
sudo sysctl --system

# 执行date命令，查看时间是否异常
date
# 更换时区
sudo timedatectl set-timezone Asia/Shanghai
# 安装ntp服务
apt install -y ntp
# 启动服务
systemctl start ntp

# Prepare to install containerd
tar Cvzxf /usr/local ${base_dir}/bin/containerd-1.6.32-linux-amd64.tar.gz

# 通过 systemd 启动 containerd
containerd_service="/etc/systemd/system/containerd.service"
if [ -e "${containerd_service}" ]; then
  rm -f "${containerd_service}"
fi

touch ${containerd_service}

cat >> ${containerd_service} << EOF
# Copyright The containerd Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
#uncomment to enable the experimental sbservice (sandboxed) version of containerd/cri integration
#Environment="ENABLE_CRI_SANDBOXES=sandboxed"
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
# Comment TasksMax if your systemd version does not supports it.
# Only systemd 226 and above support this version.
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF

# 加载配置、启动
systemctl daemon-reload
systemctl enable --now containerd
# 验证
ctr version
#生成配置文件
mkdir /etc/containerd
containerd_config="/etc/containerd/config.toml"
if [ -e "${containerd_config}" ]; then
  rm -f "${containerd_config}"
fi
touch ${containerd_config}
containerd config default > ${containerd_config}
systemctl restart containerd


# 安装 runc
install -m 755 ${base_dir}/bin/runc.amd64 /usr/local/sbin/runc
# 验证
runc -v

# 安装CNI
mkdir -p /opt/cni/bin
tar Cxzvf /opt/cni/bin ${base_dir}/bin/cni-plugins-linux-amd64-v1.5.0.tgz

# 咱有v2ray先不配置了
# # 配置加速器，非必须
# #参考：https://github.com/containerd/containerd/blob/main/docs/cri/config.md#registry-configuration
# #添加 config_path = "/etc/containerd/certs.d"
# sed -i 's/config_path\ =.*/config_path = \"\/etc\/containerd\/certs.d\"/g' /etc/containerd/config.toml
# mkdir /etc/containerd/certs.d/docker.io -p
# # 下述https://xxxx.mirror.aliyuncs.com为阿里云容器镜像加速器地址，搜索阿里云容器服务复制即可
# cat > /etc/containerd/certs.d/docker.io/hosts.toml << EOF
# server = "https://docker.io"
# [host."https://xxxx.mirror.aliyuncs.com"]
#   capabilities = ["pull", "resolve"]
# EOF
# systemctl daemon-reload && systemctl restart containerd

# kubelet 和底层容器运行时都需要对接控制组 为 Pod 和容器管理资源 ，如 CPU、内存这类资源设置请求和限制。
# 若要对接控制组（CGroup），kubelet 和容器运行时需要使用一个 cgroup 驱动。 关键的一点是 kubelet 和容器运行时需使用相同的 cgroup 驱动并且采用相同的配置。
#把SystemdCgroup = false修改为：SystemdCgroup = true
sed -i 's/SystemdCgroup\ =\ false/SystemdCgroup\ =\ true/g' ${containerd_config}
# kylecui: this seems not be necessary
# 把sandbox_image = "k8s.gcr.io/pause:3.6"修改为：sandbox_image="registry.aliyuncs.com/google_containers/pause:3.8"
# sed -i 's/sandbox_image\ =.*/sandbox_image\ =\ "registry.aliyuncs.com\/google_containers\/pause:3.8"/g' /etc/containerd/config.toml|grep sandbox_image
# 重新加载并重启
systemctl daemon-reload 
systemctl restart containerd

# kubernetes中使用crictl管理容器，不使用ctr。 配置crictl对接ctr容器运行时。
tar Cxzvf /usr/local/bin/ ${base_dir}/bin/crictl-v1.30.0-linux-amd64.tar.gz
# 配置文件
crictl="/etc/crictl.yaml"
if [ -e "${crictl}" ]; then
  rm -f "${crictl}"
fi
cat >> ${crictl} << EOF
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: true
EOF
# 重新加载
systemctl restart containerd

# prepare repository for kubernetes
sudo apt update
sudo apt install -y apt-transport-https ca-certificates curl gpg
keyfile="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
if [ -e "${keyfile}" ]; then
  rm -f "${keyfile}"
fi
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o ${keyfile}
echo 'deb [signed-by='${keyfile}'] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
# # 如果不添加镜像源，会报Unable to locate package XXX，使用官方镜像源又太慢，这里使用的阿里的源
# echo "deb https://mirrors.aliyun.com/kubernetes/apt/ kubernetes-xenial main"  | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
