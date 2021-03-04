# Contour Performance Test

## Overview

The following test is used to understand the performance and scaling characteristics of both the control plane and data plane of Contour.

The overall test methodology involves loading the system with a given number of objects, running an HTTP benchmarking tool against the system, observing the behavior of the system while handling load, and recording test results and metrics once the benchmark is complete.

In order to understand the scaling characteristics of the system, the process described above is run multiple times with different parameters for the following variables:

- \# of Concurrent Connections
- Requests per Second
- \# of HTTPProxies
- \# of Services
- \# of Endpoints

A set of test cases are prescribed in this document to avoid the combinatorial explosion of tests that would arise otherwise if all variables were to be tested individually.

In terms of infrastructure, the test is performed inside a single Kubernetes cluster.
To minimize noisy neighbor problems, each node in the cluster is assigned a test role by way of Kubernetes labels which are used to target the deployment of the pods to specific nodes.

## Goals

- Quantify the performance of the control and data plane under heavy load
- Understand the scaling characteristics to identify limiting factors
- Detect performance regressions before releasing new versions
- Validate performance improvements when performance-related changesets are introduced
- Be conscious when it comes to infrastructure spend

## Non-Goals

- Push the system to achieve a set metric (RPS, concurrent connections, etc) as this is highly dependent on the underlying infrastructure
- Automation of the infrastructure deployment
- Automation of the performance test
- Microbenchmarking specific aspects of Contour/Envoy/Gimbal

## Pre-requisites

- Kubernetes cluster with 6 worker nodes
- Have read the entire document before getting hands-on-keyboard

## Setup

### Label nodes

The pods deployed during the test will be targeted at specific nodes. This avoids one workload affecting the performance of another, it more closely mirrors the real world, and it makes the results more consistent as the workloads land on the same machines across all test runs.

| Node Role | Label | Description |
| --- | --- | --- |
| wrk | workload=wrk | The HTTP benchmarking tool will be deployed with a selector for this node. |
| contour | workload=contour | Contour will be deployed with a selector for this node. Contour and Envoy are deployed separately.Grafana and Prometheus will also be pinned to this node. |
| envoy | workload=envoy | Envoy will be deployed with a selector for this node. Contour and Envoy are deployed separately. |
| nginx | workload=nginx | Nginx will be deployed with a selector for this node. |

### Determine network bandwidth

Having a good understanding of the available bandwidth is key when it comes to analyzing performance. It will give you a sense of how many requests per second you can expect to push through the network you are working with.

Use iperf3 to figure out the bandwidth available between two of the kubernetes nodes. The following will deploy an iperf3 server on the envoy node, and an iperf3 client on the wrk node. To get the results, look at the iperf3-client pod logs.

```bash
kubectl apply -f deployment/iperf
```

Example output:
```
[ ID] Interval           Transfer     Bandwidth       Retr
[  4]   0.00-60.00  sec  6.79 GBytes   971 Mbits/sec  398             sender
[  4]   0.00-60.00  sec  6.78 GBytes   971 Mbits/sec                  receiver

iperf Done.
```

### Deploy nginx

The nginx deployment has a custom configuration file that tweaks nginx for this test. The deployment has a node selector for `workload=nginx`.

```bash
$ kubectl apply -f deployment/nginx
```

If you have 10Gb ethernet between the nodes, use the `rosskukulinski/nginx-22kb` container image, which is a vanilla nginx container with a modified response payload that is 22 kilobytes in size. Otherwise, use the vanilla nginx container which responds with approximately 600 bytes.

### Deploy Contour/Envoy

The files in `deployment/contour` are copied from `projectcontour/contour` and are here for convenience. 

```bash
$ kubectl apply -f deployment/contour
```

#### Contour

Contour is deployed as a Kubernetes deployment with a single replica and has the following modifications:

- A node selector with `workload=contour`
- Replica count set to 1
- Disabled envoy access logs by adding the following flag to the Contour container: `--envoy-http-access-log=/dev/null`

#### Envoy

Envoy is deployed as a Kubernetes DaemonSet. The deployment files included have the following modifications:

- Node selector with `workload=envoy`
- Defined an init container that configures the kernel's core.somaxconn to `65535` and `ipv4.ip_local_port_range` to `1024 65535`:

### Create HTTPProxy

```bash
$ kubectl apply -f deployment/httpproxy
```

```yaml
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: nginx
  namespace: default
  labels:
    test: batch
spec:
  virtualhost:
    fqdn: example.com
  routes:
  - services:
    - name: nginx
      port: 80
```

### Deploy Contour monitoring stack

1. Use the deployment files found in the Contour repository. However, update the prometheus and grafana deployments to have a node selector of `workload=contour`.
2. Access Grafana and Import the Grafana dashboard found in the `performance-test-dashboard.json` file.

Access Grafana:

```bash
$ kubectl port-forward $(kubectl get pods -l app=grafana -n gimbal-monitoring -o jsonpath='{.items[0].metadata.name}') 3000 -n gimbal-monitoring
```

### Sanity Checks

Once all the components are deployed, run through the following process to verify everything is up and running (specifics on how to achieve these steps are assumed to be known by reader):

1. Envoy is up and running
2. Contour is up and running
3. Nginx is up and running
4. You are able to reach nginx via an HTTPProxy
5. Run a two minute wrk2 test with 10k RPS (Set `--duration=120` & `--rate=10000`). Verify that the dashboards reflect 10k for both upstream and downstream `Total Connections`. Check the wrk2 results to make sure all requests were successful, and latency is reasonable (P99 under 10ms)
6. Run a two minute tcpkali workload with 10k concurrent connections (Set `--duration=120` & `--connections=10000`). Verify that the dashboard reflects 60k downstream connections (10k * 6 nodes). Upstream connections to nginx should remain at 0, given that all tcpkali is doing is opening connections to Envoy.

_*NOTE*: Upstream Total Connections may never hit the request amount due to Envoy connection pooling._

## Test #1: Concurrent Connections &amp; Requests/sec

This test involves starting tcpkali to open a large number of connections against Envoy, waiting until all connections are reflected in the grafana dashboard, starting wrk2 to open additional connections and drive traffic, and finally gathering results for P99 latency and cpu, memory, network utilization.

The total duration of each test run is around 10 minutes. You might need to adjust depending on your environment, but these run durations have worked well in the past:

- Tcpkali: Run for a total of 7 minutes
- Wrk2: Run for a total of 5 minutes

Nine tests in total are performed, following this test matrix:

| |  | |
| --- | --- | --- |
| 100k CC + 10k RPS | 100k CC + 20k RPS | 100k CC + 30kRPS |
| 200k CC + 10k RPS | 200k CC + 20k RPS | 200k CC + 30k RPS |
| 300k CC + 10k RPS | 300k CC + 20k RPS | 300k CC + 30k RPS |

CC = concurrent connections are configured with tcpkali 
RPS = requests per second are configured with wrk2

<sub>
* The majority of these connections are opened by tcpkali and remain open but idle.
</sub>

### Steps

1. Set the wrk2 job `--rate` parameter to the target RPS
2. Set the tcpkali job completions and parallelism parameters to N, where N is the target number of concurrent connections divided by 50,000. For example, if the target is 100,000, you will run a total of 2 tcpkali pods.
3. Create the tcpkali job
4. Wait until the dashboard reflects the target number of concurrent connections (Note: If the number on the dashboard does not reach the target, you might be running into resource exhaustion and you will most likely get errors in the tcpkali logs).
5. Start the wrk2 job to drive the target RPS through the system.
6. While both tcpkali and wrk2 are running, monitor the grafana dashboard. Make sure that the system is doing what you expect.
7. Monitor the wrk2 logs and record the P99 latency that was observed at the end of the test. Also verify that no socket timeouts where observed, and that there were zero non-200 responses.
8. Record the P99 latency in the results spreadsheet
9. Open the grafana dashboard. Select "Last 15 minutes" in the top-right dropdown.
10. We now want to drill down into the timespan in which the test was running. One way to do this is to look at the Downstream RPS panel, and click-and-drag over the spike in RPS to zoom in.
11. Once you are zoomed into the timespan in which the test was running, collect the average Envoy CPU utilization from the "_Pod CPU Usage_" panel. You might have to further zoom in to get rid of the ramp-up/ramp-down pieces of the graph. **The important thing here is to be consistent in this data gathering across test runs.**
12. Record Envoy's average CPU utilization in the results spreadsheet
13. Collect Envoy's max memory utilization from the "_Pod Memory Usage_". Record in the results spreadsheet.
14. Collect Envoy's average network throughput for the transmit metric from the "_Envoy network I/O pane"_. In grafana, this metric is the one that shows up on the legend as `<-envoy-xxxxx`
15. Take a screenshot of the grafana dashboard. There is a chrome plugin called ["Full Page Screen Capture"](https://chrome.google.com/webstore/detail/full-page-screen-capture/fdpohaocaechififmbbbbbknoalclacl?hl=en) that is useful for this. Name this file something like `xxxk-connections-yyk-rps.png`, where xxx is the number of concurrent connections, and yy is the number of RPS.
16. Delete the tcpkali pods and wrk2 job

    ```bash
    kubectl delete pod -l app=tcpkali
    kubectl delete job -l workload=wrk2
    ```

17. Once results are gathered, update the wrk2 pod spec for the next test.
18. Wait until the number of connections and RPS graphs have gone down to zero before starting the next test. Note: They may go down to 1 or 2, and this is OK as Prometheus scrapes Envoy.

## Test #2: Number of HTTPProxies and Services

This test is similar to test #1, but it focuses on another set of variables. Instead of varying the number of connections and requests per second, we vary the number of HTTPProxies and Services that exist in the cluster.

Three test runs are performed, all of them targeting a total of 300k concurrent connections and 30k requests/second:

- 1000 HTTPProxies and 1000 Services
- 2000 HTTPProxies and 2000 Services
- 3000 HTTPProxies and 3000 Services

The test involves creating a single nginx deployment that is fronted by N services, and creating N HTTPProxies, each referencing a different service. That is, HTTPProxy X has a single route that points to Service X.

During load testing, all HTTPPRoxy-Service pairs are exercised. To achieve this, N wrk2 processes are started, each setting the host header to a different FQDN and sending 30000/N requests/second. Given that we need to start up to 3000 wrk2 processes, we will run them all in a couple of pods, instead of creating thousands of pods.

### Steps

#### Setup
1. Delete the envoy and contour pods to start with fresh processes and remove any leftover state/cache/etc from the previous test. Wait until k8s recreates the pods.
2. Scale the nginx deployment to 10 replicas
3. Create two wrk2 pods to run the wrk2 processes. Use the following podspec:

    ```yaml
    apiVersion: v1
    kind: Pod
    metadata: 
    generateName: wrk2-
    namespace: default
    spec: 
    containers: 
        - args: 
            - tail
            - "-f"
            - /dev/null
        image: "alexbrand/wrk2:xenial"
        name: wrk2-one
    initContainers: 
        - command: 
            - sh
            - "-c"
            - "sysctl -w net.ipv4.ip_local_port_range=\"1024 65535\""
        image: "alpine:3.6"
        imagePullPolicy: IfNotPresent
        name: sysctl-set
        securityContext: 
            privileged: true
    nodeSelector: 
        workload: wrk
    ```

4. Open two terminal sessions and exec into the wrk2 pods we created above. Use `bash` as the command. Keep this terminal windows open, as we will use them soon to run the wrk2 processes.


### Test Run #1

1. Generate 1000 HTTPProxies and Services using the generate.sh script
1. Submit the HTTPProxies and Services to the cluster using parallel-create.sh script.
1. Start the tcpkali job with completions and parallelism set to 6 to create 300,000 concurrent connections against Envoy.
1. Monitor grafana dashboards and wait until the 300k connections have been opened
1. The following two steps are to be run in parallel. The idea is that we want to start wrk two processes on both pods at the same time to reach the 30k RPS.
1. In wrk2-one, run the following to create 500 wrk2 processes, each sending 30 rps:

    ```bash
    for i in {1..500}
    do
        wrk --latency --connections 1 --threads 1 --duration 5m --rate 30 --header "Host: dns-$i.example.com" http://envoy.contour.svc.cluster.local > wrk$i.log &
    done
    ```

2. In wrk2-two, run the following to create 500 wrk2 processes, each sending 30 rps:

    ```bash
    for i in {1..500}
    do
        wrk --latency --connections 1 --threads 1 --duration 5m --rate 30 --header "Host: dns-$((i+500)).example.com" http://envoy.contour.svc.cluster.local > wrk$((i+500)).log &
    done
    ```

3. Gather Envoy cpu, memory and network utilization metrics from the grafana dashboards. (This should follow the same data gathering process as described in test #1)
4. Gather latency numbers from the wrk2 logs. In both wrk2 pods, run the following command to get a list of latencies. Use `sort` and `head` to further analyze the results:

    ```bash
    grep --no-filename 99.000 wrk*
    ```

5. Take a screenshot of the grafana dashboard.
6. Delete the envoy and contour pods to start with fresh processes and remove any leftover state/cache/etc from the previous test. Wait until k8s recreates the pods.

#### Test Run #2:
1.  Generate 2000 HTTPProxy and Services using the generate.sh script
2.  Submit the HTTPProxy and Services to the cluster using parallel-create.sh
3.  Start 6 tcpkali pods to create 300,000 concurrent connections against Envoy.
4.  In wrk2-one, run the following to create 1000 wrk2 processes, each sending 15 rps:

    ```bash
    for i in {1..1000}
    do
        wrk --latency --connections 1 --threads 1 --duration 5m --rate 15 --header "Host: dns-$i.example.com" http://envoy.contour.svc.cluster.local > wrk$i.log &
    done
    ```

5. In wrk2-two, run the following to create 1000 wrk2 processes, each sending 20 rps:

    ```bash
    for i in {1..1000}
    do
        wrk --latency --connections 1 --threads 1 --duration 5m --rate 15 --header "Host: dns-$((i+1000)).example.com" http://envoy.contour.svc.cluster.local > wrk$((i+1000)).log &
    done
    ```

6. Gather Envoy CPU, memory and network metrics as in the previous test run.
7. Gather wrk2 latency numbers as in the previous test run.
8. Take a screenshot of the grafana dashboard.
9. Delete the envoy and contour pods to start with fresh processes and remove any leftover state/cache/etc from the previous test. Wait until k8s recreates the pods.

#### Test Run #3
1.  Generate 3000 HTTPProxies and Services using the generate.sh script
2.  Submit the HTTPProxies and Services to the cluster using parallel-create.sh
3.  Start 6 tcpkali pods to create 300,000 concurrent connections against Envoy.
4.  In wrk2-one, run the following to create 1500 wrk2 processes, each sending 10 rps:

    ```bash
    for i in {1..1500}
    do
        wrk --latency --connections 1 --threads 1 --duration 5m --rate 10 --header "Host: dns-$i.example.com" http://envoy.contour.svc.cluster.local > wrk$i.log &
    done
    ```

5.  In wrk2-two, run the following to create 500 wrk2 processes, each sending 30 rps:

    ```bash
    for i in {1..1500}
    do
        wrk --latency --connections 1 --threads 1 --duration 5m --rate 10 --header "Host: dns-$((i+1500)).example.com" http://envoy.contour.svc.cluster.local > wrk$((i+1500)).log &
    done
    ```

6.  Gather Envoy CPU, memory and network metrics as in the previous test run.
7.  Gather wrk2 latency numbers as in the previous test run.
8.  Take a screenshot of the grafana dashboard.

## Troubleshooting

These are some general troubleshooting tips and things to check for if you are seeing unexpected performance numbers, timeouts, non-successful responses, etc:

- Check the network bandwidth, and make sure you are not trying to push too much data through the pipes
- Verify that all processes involved (nginx, envoy, wrk) have enough CPU to work with. If you see they are consuming close to 80-100% of the available CPU, it might be good to scale up the underlying machine.
- Adjust the wrk2 parameters, namely the number of threads and connections. Depending on the hardware, you might have to increase or reduce these.
- If wrk2 is reporting non-200 responses, verify that you are using the correct Host header, and that your HTTPProxy is valid, and sending traffic to the right service.



## Appendix 1. AWS Suggested Infrastructure

This is what the team has used in the past to run the tests on AWS infrastructure.

- Heptio Quickstart with 5 m4.2xlarge nodes
- Add an additional m4.4xlarge node after the cluster is up and running. I have done this in the AWS console by selecting one of the nodes of the cluster (not the master), and choosing "Launch more like this" in the drop down menu. This will take you through a launch wizard where you can update the instance type to m4.4xlarge.
- The m4.4xlarge node should be labeled with workload=envoy.