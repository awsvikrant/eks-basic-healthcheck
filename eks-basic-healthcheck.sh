#!/bin/bash 
#set -ex

source ~/.bash_profile


if [ "$#" -ne 2 ]
then
	echo "Please provide InstanceID and EKS cluster name. For example ./eks-basic-healthchek i-1234567890abcdef0 devel" >&2
	exit 1
fi

if [ ! -z $1 ]
then
	InstanceID=$1
    Ec2State=$(aws ec2 describe-instances --instance-ids $InstanceID --query 'Reservations[*].Instances[*].State.Name' --output text)
    if [ "$Ec2State" != "running" ]
    then
    	echo " EC2 instance state $1 is not running"
    	exit 1
    fi
else
	echo "Please provide InstanceID"
	exit 1
fi

if [ ! -z $2 ]
then
	EKSCluster=$2
    EksStatus=$(aws eks describe-cluster --name $EKSCluster --query 'cluster.status' --output text)
    if [ $EksStatus != "ACTIVE" ]
    then 
    	echo " EKS Cluster status not ACTIVE"
    	exit 1
    fi
else
	echo "Please provide EKS Cluster Name"
	exit 1
fi



ClusterSecurityGroup=$(aws eks describe-cluster --name $EKSCluster --query 'cluster.resourcesVpcConfig.securityGroupIds' --output text)
WorkerSecurityGroup=$(aws ec2 describe-instances --instance-ids $InstanceID --query 'Reservations[0].Instances[0].NetworkInterfaces[0].Groups[0].GroupId' --output text)
VpcId=$(aws eks describe-cluster --name $EKSCluster --query 'cluster.resourcesVpcConfig.vpcId' --output text)


# Check IAM Role name configured in ConfigMap and instance IAM Role
credential_check() {

	InstanceProfile=$(aws ec2 describe-instances --instance-ids $InstanceID --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' --output text | awk -F '/' '{print $NF}')

	InstanceRoleArn=$(aws iam get-instance-profile --instance-profile-name $InstanceProfile --query 'InstanceProfile.Roles[0].Arn' --output text)
	KubeConfigArn=$(kubectl describe configmap -n kube-system aws-auth |grep rolearn | awk '{print $NF}')

	if [ $InstanceRoleArn == $KubeConfigArn ];
	then
		echo " Correct $InstanceRoleArn is configured in ConfigMap"
	else
		echo " Wrong $InstanceRoleArn is configured in ConfigMap"
	fi

}


#Check Tags of VPC and Subnets
tags_check(){

	ClusterTag="kubernetes.io/cluster/"$EKSCluster
	ListOfTags=$(aws ec2 describe-instances --instance-ids $InstanceID --query 'Reservations[0].Instances[0].Tags[].Key' --output text)
    
    echo "=====Check EC2 Instance Tags====="
    if [[ $ListOfTags == *$ClusterTag* ]]
	then
		echo " Subnet Tags matched $ClusterTag"
	else
		echo " EC2 Instances required tags are missing. Check if specify correct subnet EC2 instance-ids"
	fi
    
    echo "=====Check VPC Tags====="
	VpcTags=$(aws ec2 describe-vpcs --vpc-id $VpcId --query 'Vpcs[0].Tags[?Value==`shared`]' --output text | awk '{print $1}')

	if [[ $VpcTags == *$ClusterTag* ]]
	then
		echo " VPC Tags match $VpcTags = $ClusterTag"
	else
		echo " VPC Tags does not match $VpcTags = $ClusterTag"
	fi

    echo "=====Check Subnet Tags====="
	ListofSubnets=$(aws eks describe-cluster --name $EKSCluster --query 'cluster.resourcesVpcConfig.subnetIds' --output text)
    for sub in $ListofSubnets
    do
    	SubTag=$(aws ec2 describe-subnets --subnet-id $sub --query 'Subnets[0].Tags[?Value==`shared`]' --output text | awk  '{print $1}')
    	if [[ $SubTag == $ClusterTag ]]
        then
            echo " Subnetid $sub tag match $SubTag"
        else
        	echo " Subnetid $sub tag does not match $SubTag"
        fi

        ElbTags=$(aws ec2 describe-subnets --subnet-id $sub --query 'Subnets[*].Tags[?Key==`kubernetes.io/role/internal-elb`]' --output text | awk '{print $1}')
        
        if [[ $ElbTags == 'kubernetes.io/role/internal-elb' ]]
        then
        	echo "Subnet Id - $sub has intenral-elb tag"
        elif [[ $ElbTags == 'kubernetes.io/role/elb' ]]
        then
        	echo "Subnet Id - $sub has kubernetes.io/role/elb tag"
        fi

    done
}


#Check Cluster SG to allow traffic on port 443
sg_443(){

    ip_permission_443=$(aws ec2 describe-security-groups --filters Name=ip-permission.from-port,Values=443 Name=ip-permission.to-port,Values=443 Name=ip-permission.cidr,Values='0.0.0.0/0' --query 'SecurityGroups[*].[GroupId]' --output text)
    ip_permission_sg=$(aws ec2 describe-security-groups --filters Name=ip-permission.from-port,Values=443 Name=ip-permission.to-port,Values=443 Name=ip-permission.group-id,Values=$WorkerSecurityGroup --query 'SecurityGroups[*].[GroupId]' --output text)

    if [[ $ip_permission_sg == *$ClusterSecurityGroup* ]] || [[ $ip_permission_443 == *$ClusterSecurityGroup* ]]
    then
    	echo " Cluster Security Group allow inbound traffic on port 443"
    else
    	echo " Cluster Security Group deny traffic on port 443"
    fi

    if [[ $ip_permission_sg == $WorkerSecurityGroup ]] || [[ $ip_permission_443 == $WorkerSecurityGroup ]] 
    then
    	echo " Worker Nodes Security Group allow inbound traffic on port 443"
    else
    	echo " Worker Nodes Security Group deny traffic on port 443"
    fi

}

# Boilerplate
echo "---------------Check Ec2 Instance IAM Role ---------------" 
echo 
credential_check 
echo
echo "----------------- Check EKS required Tags -----------------"
tags_check
echo
echo "----------------- Check EKS Security Groups Rules -----------------"
echo
sg_443
