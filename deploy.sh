set -ex
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST} <<'EOSSH'
IMAGE_LOCATION=/var/lib/libvirt/images
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

function spawn_undercloud() {
    echo are
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


ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST} <<EOSSH
echo ${LAB_CIDR} > lab_cidr.txt
EOSSH
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST} <<EOSSH
echo ${LAB_CIDR} > lab_cidr.txt
EOSSH

ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST} <<'EOSSH'
MAC=$(virsh dumpxml undercloud | grep -w "mac address" | awk NR==1 | cut -d "'" -f2)
LAB_CIDR=$(cat lab_cidr.txt)
IP=$(nmap -sP ${LAB_CIDR} | grep -i "$MAC" -B 2 | awk -F\( 'NR==1 {print$2}' | awk -F\) '{print$1}')
echo $IP > ip.txt
EOSSH


scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${VIRTUALIZATION_HOST}:/root/ip.txt .
UNDERCLOUD_HOST=$(cat ip.txt)
echo "OSP version is $OSP_VERSION"
echo "OSP build is $OSP_BUILD"
echo "Underclud host is $UNDERCLOUD_HOST"
pushd ops-tools/ansible/undercloud
###################################################################################
# Set required variables
sed -i "/^rhos_release_rpm:/c rhos_release_rpm: ${RHOS_RELEASE_RPM}" vars/main.yml
sed -i "/^rhos_release:/c rhos_release: ${OSP_VERSION}-director" vars/main.yml
sed -i "/^version:/c version: ${OSP_VERSION}" vars/main.yml
sed -i "/^build:/c build: ${OSP_BUILD}" vars/main.yml
sed -i "/^local_interface:/c local_interface: $INTERFACE" vars/main.yml
sed -i "/^dns_server:/c dns_server: $DNS" vars/main.yml
sed -i "/^deploy_external_private_vlan:/c deploy_external_private_vlan: $PRIVATE_EXTERNAL" vars/main.yml
sed -i "/^instackenv_json:/c instackenv_json: $INSTACKENV" vars/main.yml
sed -i "/^rhel_version/c rhel_version: $RHEL_VERSION" vars/main.yml
sed -i "/^additional_insecure_registry/c additional_insecure_registry: $INSECURE_REGISTRY" vars/main.yml
sed -i "/^container_namespace/c container_namespace: $NAMESPACE" vars/main.yml
sed -i "/^local_docker_registry/c local_docker_registry: $LOCAL_REGISTRY" vars/main.yml
sed -i "/^clean_nodes/c clean_nodes: $NODE_CLEANING" vars/main.yml
sed -i "/^external_vlan_device/c external_vlan_device: $EXTERNAL_VLAN_DEVICE" vars/main.yml

LINK=${REPO}/${OSP_VERSION}.0-RHEL-7/${OSP_BUILD}/container_images.yaml
wget $LINK
TAG=$(cat container_images.yaml | grep $NAMESPACE | head -n 1  | awk -F ":" '{print$3}')
sed -i "/^containers_tag/c containers_tag: $TAG" vars/main.yml
cat <<EOF > hosts
[undercloud]
$UNDERCLOUD_HOST
EOF
cat vars/main.yml
###################################################################################
echo "deploying undercloud"
ansible-playbook -i hosts deploy-undercloud.yml
popd
UNDERCLOUD_HOST=$(cat ip.txt)
ssh -T -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ~/.ssh/id_rsa root@${UNDERCLOUD_HOST} <<'EOSSH'
su - stack
source ~/stackrc
#handle failed cleaning
failed_nodes=$(openstack baremetal node list | grep failed | awk {'print$2'})
wait_nodes=$(openstack baremetal node list | grep "clean wait" | awk {'print$2'})
while [ "$failed_nodes" != "" -o "$wait_nodes" != "" ]; do
    echo here
    for fail_retry in {1..5}; do
        if [ "$failed_nodes" != "" ]; then
            for node in "$failed_nodes"; do
                openstack baremetal node maintenance unset $node
                openstack baremetal node manage $node
                openstack baremetal node provide $node
            done
            sleep 600
        fi
     done
     for wait_retry in {1..5}; do
         if [ "$wait_nodes" != "" ]; then
             for node in "$wait_nodes"; do
                 openstack baremetal node maintenance set $node
                 openstack baremetal node abort $node
                 openstack bare node maintenance unset $node
                 openstack baremetal node manage $node
                 openstack baremetal node provide $node
             done
             sleep 600
         fi
     done
done
rm -rf templates/*
if [ ! -d openstack-templates ]; then
    git clone https://github.com/redhat-performance/openstack-templates.git
fi
cp -r openstack-templates/RDU-Perf/Newton/Dell/. templates/
# tag nodes
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
#deploy overcloud
time openstack overcloud deploy --templates -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e templates/network-environment.yaml -e /home/stack/docker_registry.yaml --control-scale 3 --compute-scale 2 --control-flavor control --compute-flavor compute --ntp-server clock.redhat.com > overcloud_deploy.log 2>&1
EOSSH


