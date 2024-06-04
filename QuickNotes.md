# 写在最前
给k8s命令提供autocompletion，如果没有安装`bash-completion`，需要提前安装`sudo apt install bash-completion`
```bash
source <(kubectl completion bash)
```
以后都自动加载
```bash
echo "source <(kubectl completion bash)" >> ~/.bashrc
```
# K8s的常用控制
## 查看node、pod、service等
```bash
kubectl get nodes -A -o wide
```
以上是查看所有节点的命令，其中`-A`表示`--all-namespaces`，即，列出所有namespace
`-o`的选项有`wide`，表示可以列出更多的列，也可以是`yaml`，会以yaml格式列出所有的配置信息。
```bash
kubectl get pods -A -o wide
```
```bash
kubectl get svc -A -o wide
```
## 下面以pod为例，列出更多查看命令
### 查看pod的详细信息
```bash
kubectl describe pods/pod-name
```
### 查看pod的日志
```bash
kubectl logs pods/pod-name
```
### 查看pod的yaml配置文件
```bash
kubectl get pods/pod-name -o yaml
```

## 关于DNS
所有的服务都可以通过`<service-name>.<namespace>.svc.cluster.local`来访问。但是在Ubuntu上，由于`systemd-resolved`接管了dns解析，并且创建了`/run/systemd/resolve/stub-resolv.conf`，我们无法直接使用k8s的coredns服务。这时需要：
1. modify `/etc/systemd/resolved.conf` to set the DNS servers.
2. backup `/etc/resolv.conf` (disconnect the link from `/run/systemd/resolve/stub-resolv.conf`) and link `/run/systemd/resolve/resolv.conf` to `/etc/resolv.conf`.
3. `restart systemd-resolved service`.
`setLocalDNS.sh`是解决这个问题的脚本。

## 修改配置
以修改svc/nginx-service的暴露端口为例，首先查看svc的配置
```bash
kubectl get svc/nginx-service -o yaml
```
找到需要修改的配置
```yaml
apiVersion: v1
kind: Service
metadata:
  # ...
spec:
  # ...
  ports:
  - port: 80 # <=== we are going to modify this port. 
    protocol: TCP
    targetPort: 80
  selector:
    app: nginx
  # ...
```
运行下面的命令并找到需要修改的配置，修改以后保存退出（`vim`编辑器）
```bash
kubectl edit svc nginx-service
```

## 直接在命令行修改配置
这时，我们需要利用-p参数，并且使用json的方式表达yaml，以这个服务为例：
```bash
kubectl get svc/ingress-nginx-controller -n ingress-nginx -o yaml
```
```yaml
apiVersion: v1
kind: Service
metadata:
# ...
spec:
  allocateLoadBalancerNodePorts: true
  clusterIP: 10.98.122.223
  clusterIPs:
  - 10.98.122.223
  # we are going to add this, externalIPs: [10.174.28.98]
  externalIPs: 
  - 10.174.28.98 
# ...
  type: LoadBalancer
status:
  loadBalancer: {}
```
需要执行的命令为：
```bash
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec": {"type": "LoadBalancer", "externalIPs":["10.174.28.98"]}}'
```
在`-p`参数中，我们使用了`json`的方式表达`yaml`，每缩进一个层级，使用一组`{}`，对于列表`-`则使用`[]`表示。*需要注意的是，前一个修改端口的操作用这个方式总会报错，我还在研究*


