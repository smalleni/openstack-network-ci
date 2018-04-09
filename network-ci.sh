set -x
# ssh to hypervisor to delete any existing undercloud VMs and spawn new undercloud VM
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST} <<'EOSSH'
IMAGE_LOCATION=/var/lib/libvirt/images
# Delete any running undercloud VMs and remove existing libvirt images
function cleanup() {
    echo $IMAGE_LOCATION
    virsh list --all | grep undercloud
    if [ "$?" -eq 0 ]; then
        virsh shutdown undercloud
        while true; do
	        virsh list --state-shutoff | grep -w "undercloud" | grep "shut off"
            if [[ $? == 0 ]]; then
    	        break
            fi
            sleep 10
        done
    fi
    virsh undefine undercloud
    rm -rf /var/lib/libvirt/images/*
}

# resize image to make root disk larger and copy jenkins SSH keys
function prepare_image() {
    wget -O ${IMAGE_LOCATION}/rhel-base http://download-node-02.eng.bos.redhat.com/released/RHEL-7/7.4/Server/x86_64/images/rhel-guest-image-7.4-191.x86_64.qcow2
    # resizing qcow image
    qemu-img resize ${IMAGE_LOCATION}/rhel-base +20G
    cp ${IMAGE_LOCATION}/rhel-base ${IMAGE_LOCATION}/rhel-base-orig
    virt-resize --expand /dev/sda1 ${IMAGE_LOCATION}/rhel-base-orig ${IMAGE_LOCATION}/rhel-base
    # copy jenkins ssh key to image
    MNT_PNT=/tmp/overcloud-mnt
    if [ ! -d ${MNT_PNT} ]; then
        mkdir ${MNT_PNT}
    else
        echo here
        rm -rf ${MNT_PNT}/*
    fi
    if [ -f jenkins-key ]; then
        rm jenkins-key
    fi
    wget http://8.43.86.1:8088/smalleni/jenkins-key
    guestmount -a ${IMAGE_LOCATION}/rhel-base -m /dev/sda1 ${MNT_PNT}
    pushd ${MNT_PNT}/root
    ls -talrh 
    mkdir .ssh
    chmod 700 .ssh
    pushd .ssh
    touch authorized_keys
    chmod 600 authorized_keys
    popd
    popd
    cat jenkins-key >> ${MNT_PNT}/root/.ssh/authorized_keys
    guestunmount ${MNT_PNT}
    rm -rf ${MNT_PNT}
    
}

# spawn the undercloud VM with 3 NICs- one for lab, one for provisioning and the other for 
function spawn_undercloud() {
    virt-install --import --name=undercloud\
         --virt-type=kvm\
         --disk path="${IMAGE_LOCATION}/rhel-base"\
         --vcpus=8\
         --ram=16000\
         --network bridge=br0\
         --network bridge=br1\
         --network bridge=br2\
         --os-type=lix\
         --os-variant=rhel7\
         --graphics vnc \
         --serial pty \
         --check path_in_use=off\
         --noautoconsole
}
cleanup
prepare_image
spawn_undercloud
sleep 420
EOSSH



ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST} <<'EOSSH'
MAC=$(virsh dumpxml undercloud | grep -w "mac address" | awk NR==1 | cut -d "'" -f2)
LAB_CIDR=$(cat lab_cidr.txt)
IP=$(nmap -sP ${LAB_CIDR} | grep -i "$MAC" -B 2 | awk -F\( 'NR==1 {print$2}' | awk -F\) '{print$1}')
echo $IP > ip.txt
EOSSH

# Get ip.txt from hypervisor to the jenkins workspace, since we need the IP to ssh to the undercloud from jenkins
scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST}:/root/ip.txt .
UNDERCLOUD_HOST=$(cat ip.txt)
echo "OSP build is $OSP_BUILD"
echo "Undercloud host is $UNDERCLOUD_HOST"
BUILD_REPO=$(wget -O RHOS_REPO.repo ${REPO}/${OSP_VERSION}.0-RHEL-7/${OSP_BUILD}/RH7-RHOS-${OSP_VERSION}.0.repo)
BUILD=$(cat RHOS_REPO.repo  | grep baseurl | head -n 1 | awk -F\/ '{print$8}')
pushd ops-tools/ansible/undercloud
###################################################################################
# Set required variables
sed -i "/^rhos_release_rpm:/c rhos_release_rpm: ${RHOS_RELEASE_RPM}" vars/main.yml
sed -i "/^rhos_release:/c rhos_release: ${OSP_VERSION}-director" vars/main.yml
sed -i "/^version:/c version: ${OSP_VERSION}" vars/main.yml
sed -i "/^build:/c build: ${BUILD}" vars/main.yml
sed -i "/^local_interface:/c local_interface: $INTERFACE" vars/main.yml
sed -i "/^dns_server:/c dns_server: $DNS" vars/main.yml
sed -i "/^deploy_external_private_vlan:/c deploy_external_private_vlan: $PRIVATE_EXTERNAL" vars/main.yml
sed -i "/^instackenv_json:/c instackenv_json: $INSTACKENV" vars/main.yml
sed -i "/^rhel_version/c rhel_version: $RHEL_VERSION" vars/main.yml
sed -i "/^clean_nodes/c clean_nodes: $NODE_CLEANING" vars/main.yml
sed -i "/^external_vlan_device/c external_vlan_device: $EXTERNAL_VLAN_DEVICE" vars/main.yml

# container specific options for OSP12 and above
if [ "${OSP_VERSION}" -ge 12 ]; then
    if [ "${OSP_VERSION}" -eq 12 ]; then
        LINK=${REPO}/${OSP_VERSION}.0-RHEL-7/${OSP_BUILD}/container_images.yaml
        wget $LINK
        TAG=$(cat container_images.yaml | grep $NAMESPACE | head -n 1  | awk -F ":" '{print$3}')
    elif [ "${OSP_VERSION}" -eq 13 ]; then
         LINK=${REPO}/${OSP_VERSION}.0-RHEL-7/${OSP_BUILD}/overcloud_container_image_prepare.yaml
         wget $LINK         
         TAG=$(cat overcloud_container_image_prepare.yaml | grep tag: | awk -F: 'NR==1{print$2}' | awk '{ sub(/^[ \t]+/, ""); print }')
    fi     
    sed -i "/^containers_tag/c containers_tag: $TAG" vars/main.yml
    sed -i "/^additional_insecure_registry/c additional_insecure_registry: $INSECURE_REGISTRY" vars/main.yml
    sed -i "/^container_namespace/c container_namespace: $NAMESPACE" vars/main.yml
    sed -i "/^local_docker_registry/c local_docker_registry: $LOCAL_REGISTRY" vars/main.yml

fi

# setup hosts file for undercloud install
cat <<EOF > hosts
[undercloud]
$UNDERCLOUD_HOST
EOF
###################################################################################
echo "deploying undercloud"
ansible-playbook -i hosts deploy-undercloud.yml
#sleep for node cleaning
sleep 300
popd

# ssh to dump some variables from the Jenkins environment onto the undercloud as files, for access in later parts of the script
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<EOSSH
echo ${OSP_VERSION} > /home/stack/osp_version.txt
echo ${NEUTRON_BACKEND} > /home/stack/neutron_backend.txt
echo ${UNDERCLOUD_HOST} > /home/stack/undercloud_host.txt
EOSSH

ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<'EOSSH'
su - stack
source ~/stackrc
#handle failed cleaning
function cleaning() {
        while true; do
            failed_nodes=$(openstack baremetal node list | grep failed | awk {'print$2'})
            if [ "$failed_nodes" != "" ]; then
                for node in $failed_nodes; do
                    openstack baremetal node maintenance unset $node
                    openstack baremetal node manage $node
                    openstack baremetal node provide $node
                done
                sleep 300
            elif [ "$failed_nodes" == "" ]; then
                break
            fi
         done
         while true; do
             wait_nodes=$(openstack baremetal node list | grep "clean wait" | awk {'print$2'})
             if [ "$wait_nodes" != "" ]; then
                 for node in $wait_nodes; do
                     openstack baremetal node maintenance set $node
                     openstack baremetal node abort $node
                     openstack baremetal node maintenance unset $node
                     openstack baremetal node manage $node
                     openstack baremetal node provide $node
                 done
                 sleep 300
             elif [ "$wait_nodes" == "" ]; then
                 break
             
             fi
         done
}

cleaning

# Clone and setup templates
rm -rf templates/*
if [ ! -d openstack-templates ]; then
    git clone https://github.com/smalleni/openstack-templates.git
fi
cp -r openstack-templates/RDU-Perf/Newton/Dell/. templates/
# tag nodes
function tag_nodes() {
    declare -A profile
    profile[yamaha]=compute
    profile[honda]=compute
    profile[triumph]=control
    profile[suzuki]=control
    profile[indian]=control
    for node_type in "${!profile[@]}"
    do 
        echo "Setting profile for node type $node_type"
        for i in $(openstack baremetal node list --format value -c UUID)
            do  
                node=$(openstack baremetal node show $i | grep -A 4 driver_info| grep $node_type)
                if [ "$node" != "" ]
                    then
                        echo "Updating node $i with profile ${profile[$node_type]}"
                        openstack baremetal node set $i --property capabilities=profile:${profile[$node_type]},boot_option:local
                 fi
            done
            
    done
}
tag_nodes
# Setup interface config file for external interface: In the future we can use the EXTERNAL_VLAN_DEVICE to set up vlaned device on the undercloud, and bridge non-VLANed device on the hypervisor with this NIC (currently the interface on hypervisor is VLANed to compensate for non-VLANed VM nic)
sudo bash -c 'cat << EOF > /etc/sysconfig/network-scripts/ifcfg-eth2
DEVICE=eth2
ONBOOT=yes
BOOTPROTO=static
MTU=1500
IPADDR=172.21.0.1
NETMASK=255.255.255.0
EOF'

# bring up interface
sudo ifup eth2

EOSSH

# Deploy overcloud
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<EOSSH
su - stack
source ~/stackrc
#deploy overcloud
function overcloud_deploy() {
    if [ $OSP_VERSION -ge 12 ]; then
        if [ $NEUTRON_BACKEND == OVS ]; then        
            sudo sed -i  "/^\s*OS::TripleO::Compute::Ports::ExternalPort:/c \  OS::TripleO::Compute::Ports::ExternalPort: /usr/share/openstack-tripleo-heat-templates/network/ports/external.yaml" /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-dvr.yaml
            sudo sed -i  "/^\s*OS::TripleO::Compute::Net::SoftwareConfig:/c \  OS::TripleO::Compute::Net::SoftwareConfig: /home/stack/templates/nic-configs/compute.yaml" /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-dvr.yaml
            time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e templates/deploy.yaml -e /home/stack/docker_registry.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-dvr.yaml --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
        elif [ $NEUTRON_BACKEND == ODL ]; then
           openstack overcloud container image prepare --namespace=${INSECURE_REGISTRY}/${NAMESPACE} --env-file=/home/stack/docker_registry.yaml --prefix=openstack --tag=${TAG} -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/neutron-opendaylight.yaml
           time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e templates/deploy.yaml -e /home/stack/docker_registry.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/neutron-opendaylight.yaml -e templates/opendaylight-transactions.yaml --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
        elif [ $NEUTRON_BACKEND == OVN ]; then
           openstack overcloud container image prepare --namespace=${INSECURE_REGISTRY}/${NAMESPACE} --env-file=/home/stack/docker_registry.yaml --prefix=openstack --tag=${TAG} -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/neutron-ovn-ha.yaml
           time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e templates/deploy.yaml -e /home/stack/docker_registry.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/neutron-ovn-ha.yaml --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
        fi
    else
        if [ $NEUTRON_BACKEND == OVS ]; then        
            sudo sed -i  "/^\s*OS::TripleO::Compute::Ports::ExternalPort:/c \  OS::TripleO::Compute::Ports::ExternalPort: /usr/share/openstack-tripleo-heat-templates/network/ports/external.yaml" /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-dvr.yaml
            sudo sed -i  "/^\s*OS::TripleO::Compute::Net::SoftwareConfig:/c \  OS::TripleO::Compute::Net::SoftwareConfig: /home/stack/templates/nic-configs/compute.yaml" /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-dvr.yaml
            time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e templates/deploy.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/neutron-ovs-dvr.yaml --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
        elif [ $NEUTRON_BACKEND == ODL ]; then
           pushd /home/stack/images
           virt-customize -a overcloud-full.qcow2 --run-command "yum -y localinstall ${RHOS_RELEASE_RPM}
           virt-customize -a overcloud-full.qcow2 --run-command 'rhos-release ${OSP_VERSION}'
           virt-customize -a overcloud-full.qcow2 --run-command "yum install -y java-1.8.0-openjdk.x86_64"
           virt-customize -a overcloud-full.qcow2 --run-command "yum install -y opendaylight"           
           openstack overcloud image upload --update-existing
           popd
           time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e templates/deploy.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/neutron-opendaylight.yaml --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
        elif [ $NEUTRON_BACKEND == OVN ]; then           
           time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e templates/deploy.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/services-docker/neutron-ovn-ha.yaml --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
        fi      
    fi
}
overcloud_deploy
EOSSH

# Clone Browbeat
echo "clone browbeat"
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<EOSSH
su - stack
# Clone Browbeat
git clone https://github.com/openstack/browbeat
# Clone Private config files
git clone https://${TOKEN}@github.com/redhat-performance/browbeat-config.git
# Repalce Ansible group vars and browbeat config file with the private repo files
cp browbeat-config/dataplane-ci/browbeat-config.yaml browbeat/
cp browbeat-config/dataplane-ci/group_vars/all.yml browbeat/ansible/install/group_vars/
EOSSH

# setup browbeat
echo "setup browbeat"
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<'EOSSH'
su - stack
OSP_VERSION=$(cat osp_version.txt)
NEUTRON_BACKEND=$(cat neutron_backend.txt)
UNDERCLOUD_HOST=$(cat undercloud_host.txt)
# generate cloud name based on neutron backend
CLOUD_NAME=openstack-dataplane-ci-${NEUTRON_BACKEND}
pushd browbeat
# set cloud name to match the graphite prefix
sed -i "/^\s*cloud_name:/c \  cloud_name: ${CLOUD_NAME}" browbeat-config.yaml
# set shaker server IP
sed -i "/^\s*server:/c \  server: ${UNDERCLOUD_HOST}" browbeat-config.yaml
pushd ansible
# set graphite prefix 
sed -i "/^graphite_prefix/c graphite_prefix: ${CLOUD_NAME}" install/group_vars/all.yml
# generate hosts file
./generate_tripleo_hostfile.sh -l
popd
popd
EOSSH

# run browbeat
# need separate SSH session since Jenkins job seems to exit after running ansible host generation
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<EOSSH
pwd
su - stack
pushd ~/browbeat/ansible
# install collectd
ansible-playbook -i hosts install/collectd-openstack.yml
# install dashboards
ansible-playbook -i hosts install/grafana-dashboards.yml
# install browbeat
ansible-playbook -i hosts install/browbeat.yml
# build shaker image
ansible-playbook -i hosts install/shaker_build.yml
popd
source ~/overcloudrc
# Create external network and set quotas
openstack network create --share --external --provider-physical-network datacentre --provider-network-type vlan --provider-segment 200 public
openstack subnet create --allocation-pool start=172.21.0.110,end=172.21.0.250 --gateway=172.21.0.1 --no-dhcp --network public --subnet-range 172.21.0.0/24 public_subnet
openstack quota set --class default --cores 100
openstack quota set --class default --instances 100
pushd ~/browbeat
source .browbeat-venv/bin/activate
#run browbeat
if ${CONTROL_PLANE} && ${DATA_PLANE}; then
./browbeat.py rally shaker || exit 0
elif ${CONTROL_PLANE}; then
./browbeat.py rally || exit 0
elif ${DATA_PLANE}; then
./browbeat.py shaker || exit 0
fi
EOSSH

if [ $NEUTRON_BACKEND == ODL ]; then
    ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<EOSSH
    su - stack
    pushd ~/browbeat/ansible
    # get open transactions
    ansible-playbook -i hosts browbeat/odl-open-transactions.yml
    popd
    #copy open transactions to browbeat directory for storage as artifacts
    cp open-transactions-* browbeat/
EOSSH
fi
  

#copy browbeat directory to workspace after tests are run
scp -r -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST}:/home/stack/browbeat .



