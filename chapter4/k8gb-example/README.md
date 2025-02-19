# K8GB Installation Scripts - WIP  
This is a WIP (Work in Progress) - When the scripts are complete, we will remove the WIP status.  
This directory contains scripts to create the two clusters used in Chapter 4's K8GB example.    
  
Once complete, the scripts in this repo will move to the K8GB main GIT repo as an example use-case, the main GIT for for the K8GB project is located at https://github.com/k8gb-io/k8gb  
  
## Requirements for Cluster Creation  
  
To create the example from the book, you will need access to the following:  
  
- (2) New Servers running Ubuntu 20.04  
- The scripts in this repo  
- A DNS server with permissions to create a new Zone that will be delegated to the CoreDNS servers in the K8s clusters  
- The required K8GB DNS entries for the CoreDNS servers in each K8s clusters (For our example, we will use a Windows 2019 Server as the DNS server)  
- All scripts assume an internal subnet range of 10.2.1.0/24    -    You will need to edit the values for your network  
      
# Using the Scripts to create the Infrastructure    
The following list contains a high level overview of how the scripts can be used to create the K8GB deployment described in Chapter 4.  
  
# Infrastructure Overview:  
## Design Overview
The demo assumes that you have your own DNS server that you can create a delegated zone in.  Our example will use a Windows Server, but any DNS server will work.  You will need to change the IP's to match your subnet - Our labe uses 10.2.1.0/24  
  
                    Kubeadm Cluster 1 (NYC)  10.2.1.157  
                   /  (MetalLB Config: 10.2.1.220-10.2.1.222)  
    --------------    (CoreDNS LB IP: 10.2.1.220)  
    - DNS Server -    
    - 10.2.1.14  -    [Example K8GB NGINX URL: fe.gb.foowidgets.k8s]  
    --------------  
                   \  
                    Kubeadm Cluster 2 (BUF)  10.2.1.119  
                      (MetalLB Config: 10.2.1.223-10.2.1.225) 
                      (CoreDNS LB IP: 10.2.1.223)  
    
### Ubuntu Server - NYC Cluster  
- Ubuntu Server 20.04, IP Address: 10.2.1.157  
- Single node Kubernetes Cluster created the script in this repo, create-kubeadm-single.sh
- MetalLB installed in the Cluster, using the configuration and installaion files in the metallb directory, install-metallb-nyc.sh, this will reserve a few IP addresses for K8s LB services (10.2.1.220-10.2.1.222)  
- K8GB and demo app installed using the script in the repo from the k8gb directory, deploy-k8gb-nyc.sh  

### Ubuntu Server - Buffalo Cluster  
- Ubuntu Server 20.04, IP Address: 10.2.1.119  
- Single node Kubernetes Cluster created the script in this repo, create-kubeadm-single.sh  
- MetalLB installed in the Cluster, using the configuration and installaion files in the metallb directory, install-metallb-buf.sh, this will reserve a few IP addresses for K8s LB services (10.2.1.223-10.2.1.225)  
- K8GB and demo app installed using the script in the repo from the k8gb directory, deploy-k8gb-buf.sh  
  
### Windows 2016/2019/2022 Server  
- Windows Server, IP address: 10.2.1.14  
- Create a new Conditional Forwarder for the gb.foowidgets.k8s zone, forwarding to both CoreDNS servers in each K8s cluster, if you are using the same subnet as our example, you would forward to: 10.2.1.220 and 10.2.1.223  
- One DNS record for each exposed CoreDNS pod in the clusters -  If using the same subnet as the example, the entries would be:  
  
  gslb-ns-nyc-gb     10.2.1.220  
  gslb-ns-buf-gb     10.2.1.223  
  
### Kubernetes Example Application  
  
The K8GB script exeecuted for each cluster will create the following:  
  
- A new k8gb namespace 
- A new demo namespace  
- k8gb will be deployed using Helm in the k8gb namespace 
- A new gslb object will be created for the demo application  
- A NGINX web server will be deployed into the demo namespace  
  
  
# Testing K8GB  
## Testing the initial deployment which defaults to NYC as the primary cluster  
Now that K8GB has been deployed to both clusters and an example web server has been deployed, we can test K8GB.  
  
Open a browser on your network and enter the name that was assigned in the gslb object, fe.gb.foowidgets.k8s  
  
Since the primary GeoTag was set to us-nyc, this should reply with the HTML page from the NYC NGINX server.  
  
## Testing failover to the Buffalo cluster  
To make the request fail over to the Buffalo cluster, we will simulate a failure in NYC by scaling the NGINX deployment to 0 replicas.  In the NYC cluster, run the following command:  
  
kubectl scale deployment nginx-fe -n demo --replicas=0  
  
This will cause K8GB to fail the record from the NYC cluster to the Buffalo cluster.  This usually happens within 1-5 seconds.  
  
Either refresh your browser window, or open a new tab/instance and enter the URL to test the NGINX server, fe.gb.foowidgets.k8s  
  
Now that the NYC site has a failed deployment, the reply from the NGINX server should be from the Buffalo instance.  
  
# Success!
This concludes the demo for K8GB.  


